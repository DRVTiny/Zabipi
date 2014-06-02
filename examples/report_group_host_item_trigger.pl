#!/usr/bin/perl -CDA
use constant {
              SETENV_FILE=>'setenv.conf',
              DFLT_CSV_FIELD_SEP=>';',
              DFLT_TEXT_QUOTE=>"'",
              DFLT_FRONTEND_HOST=>'localhost',
              DFLT_FRONTEND_LOGIN=>'Admin',
              DFLT_FRONTEND_PASS=>'zabbix',
             };
my %SETENV;
BEGIN {
 open (FH,'<',substr($0,0,rindex($0,'/')).'/'.SETENV_FILE) || die 'Cant set environment: '.SETENV_FILE.' not found!';
 %SETENV=map { chomp; $_=~m/^\s*(?<KEY>[A-Za-z0-9_-]+)\s*=\s*(?:(?<QUO>['"])(?<VAL>[^\g{QUO}]+?)\g{QUO}|(?<VAL>[^'"[:space:]]+?))\s*$/?($+{'KEY'},$+{'VAL'}):('NOTHING','NOWHERE') } grep { $_ !~ m/^\s*(?:#.*)?$/ } <FH>;
 push @INC,split(/\;/,$SETENV{'PERL_LIBS'}) if $SETENV{'PERL_LIBS'};
 close(FH);
}

use strict;
use utf8;
use JSON qw(decode_json);
use Data::Dumper;
use Getopt::LongWithUsage qw(GetOptsAndUsage);
use Monitoring::Zabipi qw(zbx zbx_last_err);

no warnings;
             
# By default... ->
my %FE=('server' => $SETENV{'ZBX_HOST'}  || DFLT_FRONTEND_HOST,
        'login'  => $SETENV{'ZBX_LOGIN'} || DFLT_FRONTEND_LOGIN,
        'pass'   => $SETENV{'ZBX_PASS'}  || DFLT_FRONTEND_PASS,
       );
# <- By default...

my %options;
@options{('staticData','lstConnPars','excludeGroups','lstBlockSeq','lstColMap','lstMethods2Debug','CSVFldSep')}=
         (substr($0,0,rindex($0,".")).'.dat',[],[],[],[],[],DFLT_CSV_FIELD_SEP,DFLT_TEXT_QUOTE);         

my %OptsDescr=(
            'synopsis'=>$0.' -s @CONNECT_OPTIONS [-g INCLUDE_GROUP] [-x @EXCLUDE_GROUPS] [-b @BLOCK_SEQ] [-d OUTDIR] [-t] [-o] [-v{1,}] [-m @COLUMN_MAP] [-f FLD_SEP] [-q TEXT_QUOTE]',
            'params'=>[
              [['t','show-triggers'],'!', \$options{'flShowTriggers'},'Добавить информацию о триггерах'],
              [['x','exclude-groups'],'=s@',$options{'excludeGroups'},'Исключить группы (параметр может быть указан несколько раз)'],
              [['g','only-groups'],'=s@',\$options{'searchGroupName'},'Вывести информацию только по группам с именами, соответствующими шаблону'],
              [['o','stdout'],'',\$options{'flWriteToSTDOUT'},'Выводить результат в стандартный поток вывода, а не в файл'],
              [['s','server'],'=s{3}',$options{'lstConnPars'},'Список параметров подключения к серверу фронтенда Zabbix: ИмяХоста Логин Пароль'],
              [['d','dirpath'],'=s',\$options{'pthWorkDir'},'Путь для сохранения файлов результата'],
              [['m','column-map'],'=i{1,100}',$options{'lstColMap'},'Порядок следования столбцов вывода (для перестановки столбцов и/или сокращения их количества)'],
              [['f','field-sep'],'=s',\$options{'CSVFldSep'},'Разделитель полей в CSV-выводе'],
              [['q','text-quote'],'=s',\$options{'TextQuote'},'Тип кавычек для обрамления текстовых пполей'],
              [['v','verbose'],'+',\$options{'flBeVerbose'},'Уровень подробности вывода отладочных соообщений (допускает многократное указание для повышения подробности вывода)'],
              [['b','blockseq'],'=s{1,100}',$options{'lstBlockSeq'},'Последовательность вывода блоков информации. Пример: -b "Host" "Item" "Group"'],
              [['data-here'],'=s',\$options{'staticData'},'Путь к файлу со статическими данными (описание формата CSV и пр.)'],
              [['debug-api-methods'],'=s{1,30}',$options{'lstMethods2Debug'},'Включить отладку для перечисленных методов Zabbix API'],
            ]
           );

GetOptsAndUsage(\%OptsDescr);

print "Following options was passed to me: \n".Dumper(\%options) if $options{'flBeVerbose'};

my $CSVPars={ 'fldsep'=>$options{'CSVFldSep'},
               'textq'=>defined($options{'TextQuote'})?substr($options{'TextQuote'},0,1):DFLT_TEXT_QUOTE,
              'fldmap'=>$options{'lstColMap'},
              'usemap'=>scalar(@{$options{'lstColMap'}}),
            };

my $flShowTriggers=$options{'flShowTriggers'};

unless ($options{'pthWorkDir'} || $options{'flWriteToSTDOUT'}) {
 print STDERR "Предупреждение: целевой каталог для записи CSV-файлов не задан (ключ -d), файлы будут созданы в $ENV{'HOME'}\n";
 $options{'pthWorkDir'}=$ENV{'HOME'};
}

if ($options{'lstConnPars'}) {
 @FE{('server','login','pass')}=@{$options{'lstConnPars'}};
 foreach (values %FE) {
  die 'Вы должны указать: "SERVER" "LOGIN" "PASSWORD" в качестве параметров для ключа -s' unless $_;
 }
}

our (%hdr,@ItemTypes,@HostAvail,@TrigPriors,@TrigVals,%MandKeys,%AttrConvs);
do $options{'staticData'} || die 'Cant include our static data file "'.$options{'staticData'}.'"';

sub getCsvLine {
 my ($what2get,$objs,$par,$passedToSubs)=@_;
 my $fldsep=$par->{'fldsep'} || ';';
 my $textq=substr($par->{'textq'},0,1);
 my @out;
 if      ($what2get eq 'row'   ) {
  foreach my $o ( @{$objs} ) {
   my $ov=$o->{'var'};
   my $p2s=defined($passedToSubs)?$passedToSubs:$ov;
   if ($ov && (ref($ov) eq 'HASH')) {
    foreach (@{$o->{'keys'}}) {
     my $v=(ref($_) eq 'CODE')?&{$_}($p2s):$ov->{$_};
     push @out,$v=~m/^[0-9]*$/?$v:$textq.$v.$textq;
    }
   } else {
    push @out, ('') x scalar @{$o->{'keys'}};
   }
  }
 } elsif ($what2get eq 'header') {
  push @out, map { $textq.$_.$textq } @{$_->{'labels'}} foreach @{$objs};
 }

 @out=map {$out[$_]} @{$par->{'fldmap'}} if (ref($par->{'fldmap'}) eq 'ARRAY') && @{$par->{'fldmap'}};

 return join($fldsep,@out);
}

sub getCsvObj {
 my ($obj,$Take2Subs)=@_;
 my $ov=$obj->{'var'};
 return [ (ref $ov eq "HASH") && %$ov?
   map { ref($_) eq 'CODE'?&{$_}( defined($Take2Subs)?$Take2Subs:$ov ):$ov->{$_} } @{$obj->{'keys'}}
       :
   ('') x scalar @{$obj->{'keys'}} ];
}

#sub csvFormat {
# my ($CSVFormat,$Vals)=@_;
# my $fldSep=$CSVFormat->{'fldsep'} || ';';
# my $txtQ=substr($CSVFormat->{'textq'},0,1);
# return $txtQ eq ''?
#     join($fldSep, @{$Vals})
#                   :
#     join($fldSep, map { $_=~m/^[0-9]*$/?$_:$txtQ.$_.$txtQ } @{$Vals});
#}

sub pushToTree {
 my ($tLevel,$slfProps)=@_;
 my $tChilds=[];
 push @{$tLevel},[$slfProps,$tChilds];
 return $tChilds;
}

sub outTree {
 my ($l,$sep,$tq)=@_;
 my @out=();
 return ('') unless @{$l};
 foreach my $e ( @{$l} ) {
  my $slf=join(';',map { $_=~m/^[0-9]*$/?$_:$tq.$_.$tq } @{$e->[0]});
  push @out,map { $slf.$sep.$_ } outTree($e->[1],$sep,$tq);
 }
 return @out;
}

sub lstTree {
 my $el=shift;
 return $el->[0] unless @{$el->[1]};
 my @slf=@{$el->[0]};
 my @out;
 foreach my $child ( @{$el->[1]} ) {
  push @out, map { [@slf,@{$_}] } lstTree($child);
 }
 return @out;
}

my @bseq=@{$options{'lstBlockSeq'}}?
          grep { defined($hdr{$_}) } @{$options{'lstBlockSeq'}}
               :
          sort { $hdr{$a}{'prefid'} <=> $hdr{$b}{'prefid'} } ($flShowTriggers?keys %hdr:grep !/Trigger/,keys %hdr);          
my @objs=map { $hdr{$_} } @bseq;

die 'There are no Zabbix objects to output defined' unless @objs;
print 'objs: '.Dumper(\@objs) if $options{'flBeVerbose'};

my %keys2rq;
foreach my $b (keys %hdr) {
 my $mk=$MandKeys{$b};
 my @rk=grep { ! (ref $_ || $_=~m/^[A-Z]/) } @{$hdr{$b}{'keys'}};
 @{$mk}{@rk}=(1) x scalar(@rk);
 $keys2rq{$b}=[ grep { $mk->{$_} } keys %$mk ];
}

Monitoring::Zabipi->new($FE{'server'},@{$options{'lstMethods2Debug'}}?{'debug_methods'=>$options{'lstMethods2Debug'}}:{});
zbx('auth',$FE{'login'},$FE{'pass'}) || die "Authorization on Zabbix frontend at $FE{'server'} failed. Error='".zbx_last_err"'";

my $parsHGSearch={output=>['groupid',@{$keys2rq{'Group'}}],'sortfield'=>'name'};
@{$parsHGSearch}{('search','searchWildcardsEnabled')}=({'name'=>$options{'searchGroupName'}->[0]},'true') if $options{'searchGroupName'};
my $rxExcludeGroups=@{$options{'excludeGroups'}}
 ?
  (@{$options{'excludeGroups'}}>1?'('.join('|',@{$options{'excludeGroups'}}).')':$options{'excludeGroups'}->[0])
 :
  '^\(';
my $grps=[ grep {my $name=$_->{'name'}; $name !~ m/$rxExcludeGroups/o && $name=~m/(?:Функции|Инфраструктура)/} @{zbx('hostgroup.get',$parsHGSearch)} ];
print "No host groups found\n" unless @{$grps};

sub convAttrs {
 my ($zbxGetRslt,$hdr,$objID,$convMap)=@_;
 $hdr->{$objID}{'var'}=$zbxGetRslt; 
 my %conv;
 return 1 unless (ref($convMap->{$objID}) eq 'HASH') and %conv=%{$convMap->{$objID}};
 foreach (keys %conv) {
  $zbxGetRslt->{$_}=&{$conv{$_}}($zbxGetRslt->{$_},$zbxGetRslt) if defined($zbxGetRslt->{$_});
 } 
 return 1;
}

my $tCSV=[];
my %tLevel=('Group'=>$tCSV);
# groups -> 
foreach my $grp ( @{$grps} ) {
 convAttrs($grp,\%hdr,'Group',\%AttrConvs);
 
 $tLevel{'Host'}=pushToTree($tLevel{'Group'},getCsvObj($hdr{'Group'},\%hdr));
 # hosts -> 
 foreach my $hst ( @{zbx('host.get',{'groupids'=>$grp->{'groupid'},'output'=>$keys2rq{'Host'}})} ) {
  convAttrs($hst,\%hdr,'Host',\%AttrConvs);
  $tLevel{'Application'}=pushToTree($tLevel{'Host'},getCsvObj($hdr{'Host'},\%hdr));

  my $hostId=$hst->{'hostid'};  
  my $apps=zbx('application.get',{'hostids'=>$hostId,'output'=>$keys2rq{'Application'}});
  my $SearchItemsByKey='applicationids';
  unless ( @{$apps} ) {
   $SearchItemsByKey='hostids';
   $apps->[0]={'name'=>'(без группы)','applicationid'=>$hostId};
  }
  # apps ->
  foreach my $app ( @{$apps} ) {
   convAttrs($app,\%hdr,'Application',\%AttrConvs);
   $tLevel{'Item'}=pushToTree($tLevel{'Application'},getCsvObj($hdr{'Application'},\%hdr));
   
   #  items ->
   foreach my $item ( @{ zbx('item.get',{$SearchItemsByKey=>$app->{'applicationid'},'expandNames'=>1,'selectTriggers'=>$flShowTriggers?'extend':'count','output'=>$keys2rq{'Item'}}) } ) {
    convAttrs($item,\%hdr,'Item',\%AttrConvs);
    $tLevel{'Trigger'}=pushToTree($tLevel{'Item'},getCsvObj($hdr{'Item'},\%hdr));
    
    next unless $flShowTriggers;
    do { pushToTree($tLevel{'Trigger'},[]); next; } unless @{$item->{'triggers'}};
    # trigs ->
    foreach my $trig ( @{zbx('trigger.get',{'triggerids'=>[map {$_->{'triggerid'}} $item->{'triggers'}],'expandExpression'=>1,'expandDescription'=>1,'output'=>$keys2rq{'Trigger'} })}  ) {
     convAttrs($trig,\%hdr,'Trigger',\%AttrConvs);     
     pushToTree($tLevel{'Trigger'},getCsvObj($hdr{'Trigger'},\%hdr));
     
    } # <- trigs
   } # <- items
  } # <- apps
 } # <- hosts 
} # <- groups

my ($csvSep,$csvTQ,$fldMap)=@{$CSVPars}{('fldsep','textq')};
my $flToSTDOUT=$options{'flWriteToSTDOUT'};
my $flUseMap=$CSVPars->{'usemap'};
my @fldmap=();
@fldmap=@{$CSVPars->{'fldmap'}} if $flUseMap;

*FH=*STDOUT if $flToSTDOUT;
foreach my $grp ( @{$tCSV} ) {
 my $groupName=$grp->[0][0];
 my $groupFileName="$options{'pthWorkDir'}/${groupName}.csv";
 unless ($flToSTDOUT) {
  open (FH,'>',$groupFileName) || die "Cant open $groupFileName for write";
  print STDERR "Пишем в файл: $groupFileName\n" if $options{'flBeVerbose'};
 }
 $hdr{'Host'}{'labels'}[0]=($groupName=~m/Функции/)?'Наименование ФИС':'Имя хоста ИИС';
 print FH getCsvLine('header',\@objs,$CSVPars)."\n";
 unless ($flUseMap) {
  print FH join("\n",map { my $line=$_; join($csvSep,map { $_=~m/^[0-9]*$/?$_:$csvTQ.$_.$csvTQ } @{$line}) } lstTree($grp))."\n";
 } else {
  print FH join("\n",map { my $line=$_; join($csvSep,map { my $e=$line->[$_]; $e=~m/^[0-9]*$/?$e:$csvTQ.$e.$csvTQ } @fldmap) } lstTree($grp))."\n";
 }
 close(FH) unless $flToSTDOUT;
}
 
=pod
#my @OUT=outTree($tCSV,$csvSep,$csvTQ);
foreach my $groupName ( map {$_->[0][0]} @{$tCSV} ) {
 my $groupFileName="$options{'pthWorkDir'}/${groupName}.csv";
 if (!$options{'flWriteToSTDOUT'}) {
  open (FH,'>',$groupFileName) || die "Cant open $groupFileName for write";
  print STDERR "Пишем в файл: $groupFileName\n" if $options{'flBeVerbose'};
 }
 $hdr{'Host'}{'labels'}[0]=($groupName=~m/Функции/)?'Наименование ФИС':'Имя хоста ИИС';
 print FH getCsvLine('header',\@objs,$CSVPars)."\n";
 print FH join("\n",grep { substr($_,0,index($_,$csvSep)) eq $csvTQ.$groupName.$csvTQ } @OUT)."\n";
 close(FH) unless $options{'flWriteToSTDOUT'};
}
=cut
