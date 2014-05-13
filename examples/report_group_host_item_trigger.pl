#!/usr/bin/perl -CDA
use utf8;
use JSON qw( decode_json );
use Data::Dumper;
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}

my $s=';';

use Monitoring::Zabipi qw(zbx);
no warnings;

my $opt;
my %options;
while (($opt=shift)=~m/^-/) {
 last if $opt eq '--';
 if ( $opt=~m/^-(?:[tT]|-trig(?:gers)?)$/ ) {
  $options{'flShowTriggers'}=1;
 } elsif ( $opt=~m/^-(?:x|-exclude-groups)/ ) {
  my $exclGroup;
  while (($exclGroup=shift) !~ m/^(?:-|$)/) {
   push @{$options{'excludeGroups'}},$exclGroup;
  }
  unshift(@ARGV,$exclGroup) if $exclGroup;
 } elsif ( $opt=~m/^-(?:g|-group)$/ ) {
  $options{'searchGroupName'}=shift;
 } elsif ( $opt=~m/^-(?:o|-stdout)$/ ) {
  $options{'writeToSTDOUT'}=1;
 } elsif ( $opt=~m/^-(?:e|-name-expand-cmd)$/ ) {
  $cmdNameExpander=shift;
 } elsif ( $opt=~m/^-(?:s|-server)$/ ) {
  ($ZBXServer,$ZBXLogin,$ZBXPass)=(shift,shift,shift);
 } elsif ( $opt=~m/^-(?:d|-dirpath)$/ ) {
  $OUT_DIR=shift;
 }
}
unshift(@ARGV,$opt) unless substr($opt,0,1) eq '-';

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

sub getHeader {
 my ($header,$blockseq)=(shift,shift);
 my $fldSep=';';
 $fldSep=scalar(shift) if @_;
 my @out=();
 foreach ( map { $header->{$_} } @{$blockseq} ) {
  push @out,join($fldSep,map { '"'.$_.'"' } @{$_->{'labels'}});
 }
 return join($fldSep,@out);
}

sub getRow {
 my ($header,$blockseq)=(shift,shift);
 my $fldSep=';';
 $fldSep=scalar(shift) if @_;
 my @out=();
 foreach ( map { $header->{$_} } @{$blockseq} ) {
  push @out,join($fldSep,map { $_=~m/^[0-9]*$/?$_:'"'.$_.'"' } @{$_->{'var'}}{ @{$_->{'keys'}} });
 }
 return join($fldSep,@out);
}

my @blocks=('Group','Host','Application','Item','Trigger');
pop(@blocks) unless $options{'flShowTriggers'};

my %hdr=('Group'=>
           {'labels'=>['Группа'],
              'keys'=>['name'  ]           
           },
         'Host'=>
           {'labels'=>['Хост','IP адрес','Статус мониторинга','Доступность агента','Сообщение об ошибке'],
              'keys'=>['name','ip'      ,'status'            ,'available'         ,'error'              ]
           },
         'Application'=>
           {'labels'=>['Группа параметров'],
              'keys'=>['name'             ]
           },
         'Item'=>
           {'labels'=>['Параметр мониторинга','Интервал опроса (сек)','Период хранения истории (дней)','Период хранения трендов (дней)','Тип параметра','Поддерживается ли агентом?','Сообщение об ошибке'],
              'keys'=>['name_expanded'       ,'delay'                ,'history'                       ,'trends',                       ,'type'         ,'state'                     ,'error'              ]
           },
         'Trigger'=>
           {'labels'=>['Триггер'     , 'Критичность', 'Статус триггера', 'Включен?', 'Как вычисляется триггер (пороговое значение)', 'Сообщение об ошибке', 'Текущее значение'],
              'keys'=>['description' , 'priority'   , 'state'          , 'status'  , 'expression'                                  , 'error'              , 'value'           ]
           }
        );
        
my $header=getHeader(\%hdr,\@blocks,$s);

Monitoring::Zabipi->new($ZBXServer);
zbx('auth',$ZBXLogin,$ZBXPass);

my $parsHGSearch={output=>['groupid',@{$hdr{'Group'}{'keys'}}],'sortfield'=>'name'};
@{$parsHGSearch}{('search','searchWildcardsEnabled')}=({'name'=>$options{'searchGroupName'}},'true') if $options{'searchGroupName'};
$rxExcludeGroups=@{$options{'excludeGroups'}}
 ?
  (@{$options{'excludeGroups'}}>1?'('.join('|',@{$options{'excludeGroups'}}).')':$options{'excludeGroups'}->[0])
 :
  '^\(';
my $grps=[ grep {$_->{'name'} !~ m/$rxExcludeGroups/o} @{zbx('hostgroup.get',$parsHGSearch,{'flDebug'=>1})} ];
print "No host groups found\n" unless @{$grps};
*FH=*STDOUT if $options{'writeToSTDOUT'};
foreach my $grp ( @{$grps} ) {
 $hdr{'Group'}{'var'}=$grp;
 
 my ($groupName,$groupId)=($grp->{'name'},$grp->{'groupid'});
 open(FH,'>',"${OUT_DIR}/${groupName}.csv") unless $options{'writeToSTDOUT'};
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
             
       print FH getRow(\%hdr,\@blocks,$s)."\n";
      } # triggers
     } else {
      $hdr{'Trigger'}{'var'}={'description'=>' '};
      printf FH getRow(\%hdr,\@blocks,$s)."\n";
     }
    } else {
     printf FH getRow(\%hdr,\@blocks,$s)."\n";
    }
   } # items
  } # apps
 } # hosts 
 close(FH);
} # groups
