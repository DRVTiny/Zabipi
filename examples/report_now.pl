#!/usr/bin/perl -CDA
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}

use strict;
use utf8;
use JSON qw(decode_json);
use Text::Aligner qw(align);
use Data::Dumper;
use Getopt::Long qw(GetOptions);
use Monitoring::Zabipi qw(zbx zbx_last_err);
use constant {
              DFLT_CSV_FIELD_SEP=>';',
              DFLT_FRONTEND_HOST=>'localhost',
              DFLT_FRONTEND_LOGIN=>'Admin',
              DFLT_FRONTEND_PASS=>'zabbix',
              DFLT_TEXT_QUOTE=>"'",
             };
no warnings;
             
# By default... ->
my %FE=('server' => DFLT_FRONTEND_HOST,
        'login'  => DFLT_FRONTEND_LOGIN,
        'pass'   => DFLT_FRONTEND_PASS
       );
# <- By default...

my %options;
@options{('staticData','lstConnPars','excludeGroups','lstBlockSeq','lstColMap','CSVFldSep')}=
         (substr($0,0,rindex($0,".")).'.dat',[],[],[],[],DFLT_CSV_FIELD_SEP,DFLT_TEXT_QUOTE);

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
            ]
           );

sub doGetOpts {
 my $descr=shift;
 my $usage="Usage:\n\t".$descr->{'synopsis'}."\n";
 my (%hsh4gol,@UsageKeys,@UsageDesc);
 push @{$descr->{'params'}},[['usage'],'',sub { print "$usage"; exit(0); },'Показать ровным счётом то, что вы видите сейчас'];
 foreach my $opt (@{$descr->{'params'}}) {
  push @UsageKeys,join (' ',map { length($_)==1?'-'.$_:'--'.$_ } @{$opt->[0]});
  push @UsageDesc,$opt->[3];
  $hsh4gol{join('|',@{$opt->[0]}).$opt->[1]}=$opt->[2];
 }
 @UsageKeys=align('left',@UsageKeys);
 @UsageDesc=align('left',@UsageDesc);
 for (my $i=0; $i<scalar(@UsageKeys); $i++) {
  $usage.=$UsageKeys[$i]."\t".$UsageDesc[$i]."\n";
 }
 GetOptions(%hsh4gol);
 return 1;
}

doGetOpts(\%OptsDescr);

print "Following options was passed to me: \n".Dumper(\%options) if $options{'flBeVerbose'};

my $CSVPars={'fldsep'=>$options{'CSVFldSep'},'textq'=>$options{'TextQuote'}?substr($options{'TextQuote'},0,1):DFLT_TEXT_QUOTE};
$CSVPars->{'fldmap'}=$options{'lstColMap'} if @{$options{'lstColMap'}};

unless ($options{'pthWorkDir'}) {
 print STDERR "Предупреждение: целевой каталог для записи CSV-файлов не задан (ключ -d), файлы будут созданы в $ENV{'HOME'}\n";
 $options{'pthWorkDir'}=$ENV{'HOME'};
}

if ($options{'lstConnPars'}) {
 @FE{('server','login','pass')}=@{$options{'lstConnPars'}};
# To be removed because of {3} in Getopt::Long. But write usage message first ;)
 foreach (values %FE) {
  die 'Вы должны указать: "SERVER" "LOGIN" "PASSWORD" в качестве параметров для ключа -s' unless $_;
 }
}

our (%hdr,@ItemTypes,@HostAvail,@TrigPriors,@TrigVals);
do $options{'staticData'} || die 'Cant include our static data file "'.$options{'staticData'}.'"';

sub getCsvLine {
 my ($what2get,$objs,$par)=@_;
 my $fldsep=$par->{'fldsep'} || ';';
 my $textq=$par->{'textq'}?substr($par->{'textq'},0,1):"'";
 my @out;
 if      ($what2get eq 'row'   ) {
  my $duh={};
  foreach ( @{$objs} ) {  
   push @out, map { $_=~m/^[0-9]*$/?$_:$textq.$_.$textq } @{$_->{'var'} || $duh}{ @{$_->{'keys'}} };
  }
 } elsif ($what2get eq 'header') {
  push @out, map { $textq.$_.$textq } @{$_->{'labels'}} foreach @{$objs};
 }

 @out=map {$out[$_]} @{$par->{'fldmap'}} if ref($par->{'fldmap'}) eq 'ARRAY';

 return join($fldsep,@out);
}

my @objs=@{$options{'lstBlockSeq'}}?
              map { $hdr{$_} } @{$options{'lstBlockSeq'}}
                  :
              sort { $a->{'prefid'} <=> $b->{'prefid'} } map { $hdr{$_} } ($options{'flShowTriggers'}?keys %hdr:grep !/Trigger/,keys %hdr);

print 'objs: '.Dumper(\@objs) if $options{'flBeVerbose'};
my $header=getCsvLine('header',\@objs,$CSVPars);

Monitoring::Zabipi->new($FE{'server'});
zbx('auth',$FE{'login'},$FE{'pass'}) || die "Authorization on Zabbix frontend at $FE{'server'} failed. Error='".zbx_last_err"'";

my $parsHGSearch={output=>['groupid',@{$hdr{'Group'}{'keys'}}],'sortfield'=>'name'};
@{$parsHGSearch}{('search','searchWildcardsEnabled')}=({'name'=>$options{'searchGroupName'}->[0]},'true') if $options{'searchGroupName'};
my $rxExcludeGroups=@{$options{'excludeGroups'}}
 ?
  (@{$options{'excludeGroups'}}>1?'('.join('|',@{$options{'excludeGroups'}}).')':$options{'excludeGroups'}->[0])
 :
  '^\(';
my $grps=[ grep {$_->{'name'} !~ m/$rxExcludeGroups/o} @{zbx('hostgroup.get',$parsHGSearch,{'flDebug'=>1})} ];
print "No host groups found\n" unless @{$grps};

*FH=*STDOUT if $options{'flWriteToSTDOUT'};

foreach my $grp ( @{$grps} ) {
 $hdr{'Group'}{'var'}=$grp;
 
 my ($groupName,$groupId)=($grp->{'name'},$grp->{'groupid'});
 open(FH,'>',"$options{'pthWorkDir'}/${groupName}.csv") unless $options{'flWriteToSTDOUT'};
 print FH $header."\n";
 foreach my $hst ( @{zbx('host.get',{'groupids'=>$groupId,output=>['hostid',@{$hdr{'Host'}{'keys'}}]})} ) {
  $hdr{'Host'}{'var'}=$hst;
  
  $hst->{'ip'}=zbx('hostinterface.get',{'hostids'=>$hst->{'hostid'},output=>['ip']})->[0]{'ip'};
  $hst->{'available'}=$HostAvail[$hst->{'available'}];
  $hst->{'status'}=$hst->{'status'}?'не выполняется':'выполняется';
  $hst->{'error'}=' ' unless $hst->{'error'};
  
  my ($hostName,$hostId)=($hst->{'host'},$hst->{'hostid'});
  my $apps=zbx('application.get',{hostids=>$hostId,output=>['applicationid',@{$hdr{'Application'}{'keys'}}]});
  my $SearchItemsByKey='applicationids';
  if (! @{$apps}) {
   $SearchItemsByKey='hostids';
   $apps->[0]={'name'=>'(без группы)','applicationid'=>$hostId};
  }
  foreach my $app ( @{$apps} ) {
   $hdr{'Application'}{'var'}=$app;
   
   my $items=zbx('item.get',{$SearchItemsByKey=>$app->{'applicationid'},'expandNames'=>1,'output'=>['itemid',@{$hdr{'Item'}{'keys'}}]});                                    
   foreach my $item ( @{$items} ) {
    $hdr{'Item'}{'var'}=$item;
    
    $item->{'type'}=$ItemTypes[$item->{'type'}];
    $item->{'state'}=$item->{'state'}?'не поддерживается':'поддерживается';
    $item->{'error'}=' ' unless $item->{'error'};
    
    if ($options{'flShowTriggers'}) {
     my $itrigs=zbx('trigger.get',{'itemids'=>$item->{'itemid'},'expandExpression'=>1,'expandDescription'=>1,'output'=>$hdr{'Trigger'}{'keys'} });
     if (@{$itrigs}) {
      foreach my $trig ( @{$itrigs} ) {
       $hdr{'Trigger'}{'var'}=$trig;
       
       $trig->{'state'}=$trig->{'state'}?'неизвестно':'актуально';
       $trig->{'value'}=$trig->{'status'}?'N/A':$TrigVals[$trig->{'value'}]; #.'('.$trig->{'value'}.')';
       $trig->{'status'}=$trig->{'status'}?'отключен':'включен';
       $trig->{'priority'}=$TrigPriors[$trig->{'priority'}];
             
       print FH getCsvLine('row',\@objs,$CSVPars)."\n";
      } # triggers
     } else {
      $hdr{'Trigger'}{'var'}={'description'=>' '};
      print FH getCsvLine('row',\@objs,$CSVPars)."\n";
     }
    } else {
     print FH getCsvLine('row',\@objs,$CSVPars)."\n";
    }
   } # items
  } # apps
 } # hosts 
 close(FH);
} # groups
