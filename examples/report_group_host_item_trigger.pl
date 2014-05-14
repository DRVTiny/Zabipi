#!/usr/bin/perl -CDA
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}

use strict;
use utf8;
use JSON qw(decode_json);
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

# Static definitions ->
my %hdr=('Group'=>
           {'labels'=>['Группа'],
              'keys'=>['name'  ],
            'prefid'=>0,
           },
         'Host'=>
           {'labels'=>['Хост','IP адрес','Статус мониторинга','Доступность агента','Сообщение об ошибке'],
              'keys'=>['name','ip'      ,'status'            ,'available'         ,'error'              ],
            'prefid'=>1,
           },
         'Application'=>
           {'labels'=>['Группа параметров'],
              'keys'=>['name'             ],
            'prefid'=>2,
           },
         'Item'=>
           {'labels'=>['Параметр мониторинга','Интервал опроса (сек)','Период хранения истории (дней)','Период хранения трендов (дней)','Тип параметра','Поддерживается ли агентом?','Сообщение об ошибке'],
              'keys'=>['name_expanded'       ,'delay'                ,'history'                       ,'trends',                       ,'type'         ,'state'                     ,'error'              ],
            'prefid'=>3,
           },
         'Trigger'=>
           {'labels'=>['Триггер'     , 'Критичность', 'Статус триггера', 'Включен?', 'Как вычисляется триггер (пороговое значение)', 'Сообщение об ошибке', 'Текущее значение'],
              'keys'=>['description' , 'priority'   , 'state'          , 'status'  , 'expression'                                  , 'error'              , 'value'           ],
            'prefid'=>4,
           }
        );

my @ItemTypes=(
   'Zabbix агент',
   'SNMPv1 агент',
   'Zabbix траппер',
   'простая проверка',
   'SNMPv2 агент',
   'внутренняя проверка Zabbix',
   'SNMPv3 агент',
   'Zabbix агент (активная)',
   'Zabbix агреггированное',
   'веб проверка',
   'внешняя проверка',
   'монитор базы данных',
   'IPMI агент',
   'SSH агент',
   'TELNET агент',
   'вычисляемое значение',
   'JMX агент',
   'SNMP ловушка'
);

my @HostAvail=('неизвестно','доступен','недоступен');
my @TrigPriors=('Не классифицировано','Информация','Низкая','Средняя','Высокая','Чрезвычайная');
my @TrigVals=('OK','Проблема');
# <- Static definitions

my %options;
@options{('lstConnPars','excludeGroups','lstBlockSeq','lstColMap','CSVFldSep')}=([],[],[],[],DFLT_CSV_FIELD_SEP,DFLT_TEXT_QUOTE);

GetOptions(
        't|show-triggers!'    => \$options{'flShowTriggers'},
        'x|exclude-groups=s@' => $options{'excludeGroups'},
        'g|only-groups=s@'    => \$options{'searchGroupName'},
        'o|stdout'            => \$options{'flWriteToSTDOUT'},
        'e|name-expand-cmd=s' => \$options{'cmdNameExpander'},
        's|server|connect-pars=s{3}'=>$options{'lstConnPars'},
        'd|dirpath=s'         => \$options{'pthWorkDir'},
        'f|field-sep=s'       => \$options{'CSVFldSep'},
        'q|text-quote=s'      => \$options{'TextQuote'},
        'm|column-map=i{1,'.scalar(keys %hdr).'}' => $options{'lstColMap'},
        'v|verbose+'           => \$options{'flBeVerbose'},
        'b|blockseq=s{1,'.scalar(keys %hdr).'}' => $options{'lstBlockSeq'},
);

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

sub getCsvLine {
 my ($what2get,$objs,$par)=@_;
 my $fldsep=$par->{'fldsep'} || ';';
 my $textq=$par->{'textq'}?substr($par->{'textq'},0,1):"'";
 my @out;
 
 if      ($what2get eq 'row'   ) {
  foreach ( @{$objs} ) {
   push @out, map { $_=~m/^[0-9]*$/?$_:$textq.$_.$textq } @{$_->{'var'}}{ @{$_->{'keys'}} };
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
