package Monitoring::Zabipi::ITServices;
use Monitoring::Zabipi qw(zbx zbx_get_dbhandle zbx_api_url zbx_last_err);
use v5.14.1;
use utf8;
use constant {
     SLA_ALGO_DO_NOT_CALC=>0,
     SLA_ALGO_ONE_FOR_PROBLEM=>1,
     SLA_ALGO_ALL_FOR_PROBLEM=>2,
     SHOW_SLA_DO_NOT_CALC=>0,
     SHOW_SLA_CALC=>1,
     DEFAULT_GOOD_SLA=>'99.05',
     IFACE_TYPE_ZABBIX_AGENT=>1,
     IFACE_TYPE_SNMP=>2,
};
my %ltr2zobj=(
 'i'=>{ 'otype'=>'item',        'id_attr'=>'itemid',        'table'=>'items', 	 	'name'=>{'attr'=>'name'},  				},
 's'=>{ 'otype'=>'service',     'id_attr'=>'serviceid',     'table'=>'services', 	'name'=>{'attr'=>'name'},  				}, 
 't'=>{ 'otype'=>'trigger',     'id_attr'=>'triggerid',     'table'=>'triggers', 	'name'=>{'attr'=>'description'},			},
 'h'=>{ 'otype'=>'host',        'id_attr'=>'hostid',        'table'=>'hosts', 	 	'name'=>{'attr'=>[qw(host name)], 'fmt'=>'%s (%s)'}, 	},
 'g'=>{ 'otype'=>'hostgroup',   'id_attr'=>'groupid',       'table'=>'groups', 	 	'name'=>{'attr'=>'name'},				},
 'a'=>{ 'otype'=>'application', 'id_attr'=>'applicationid', 'table'=>'applications', 	'name'=>{'attr'=>'name'},				},
 'u'=>{ 'otype'=>'user',        'id_attr'=>'userid',        'table'=>'users',		'name'=>{'attr'=>[qw(alias name surname)], 'fmt'=>'%s (%s %s)'}, },
 'U'=>{ 'otype'=>'usergroup',   'id_attr'=>'usergroupid',   'table'=>'usrgrp',		'name'=>{'attr'=>'name'},    				},
 'm'=>{ 'otype'=>'mediatype',   'id_attr'=>'mediatypeid',   'table'=>'media_type',	'name'=>{'attr'=>'description'},			},
 'M'=>{ 'otype'=>'media',       'id_attr'=>'mediaid',       'table'=>'media',		'name'=>{'attr'=>'sendto'}, 				},
);
our $rxZOPfxs=join ''=>keys %ltr2zobj;
my $rxZOSfx=qr/\s*(\(([${rxZOPfxs}])(\d{1,10})\))$/;

use Exporter qw(import);
our @EXPORT_OK=qw(doDeleteITService genITServicesTree getITService getAllITServiceDeps doMoveITService getServiceIDsByNames doSymLinkITService chkZObjExists doAssocITService getITServicesAssociatedWith);
our @EXPORT=qw($rxZOPfxs doDeleteITService doMoveITService doRenameITService getITService getITService4jsTree genITServicesTree getServiceIDsByNames doSymLinkITService doUnlinkITService getITSCache setAlgoITService chkZObjExists doAssocITService doDeassocITService getITServiceChildren getITServiceDepsByType doITServiceAddZOAttrs zobjFromSvcName getITServicesAssociatedWith getITServiceIDByName);

use DBI;
use Data::Dumper;


my %sql_=(
          'getSvcDeps'=>{
                                'rq'=>qq(select s.serviceid,s.name,s.algorithm,s.triggerid from services s inner join services_links l on s.serviceid=l.servicedownid where l.serviceupid=?),
          },
          'getSvc'=>	{ 	'rq'=>qq(select serviceid,name,algorithm,triggerid from services where serviceid=?), 	},
          'getSvcByZOExt' =>{	'rq'=>qq(select serviceid,name,algorithm,triggerid from services where name like concat('% (',?,')')) },
          'getSvcChildren'=>{	'rq'=>qq(select c.serviceid,c.name,c.algorithm from services_links l inner join services c on l.servicedownid=c.serviceid and l.serviceupid=?),	},          
          'getRootSvcChildren'=>{ 'rq'=>qq(select s.serviceid,s.name,s.algorithm from services s left outer join services_links l on l.servicedownid=s.serviceid where l.servicedownid is null), },
          'getTrg'=>	{ 	'rq'=>qq(select priority,value,status from triggers where triggerid=?),			},          
          'mvSvc'=>	{ 	'rq'=>qq(update services_links set serviceupid=? where servicedownid=?), 		},
          'getSvcByName'=>{ 	'rq'=>qq(select serviceid from services where name=?),					},
          'getSvcByNameAndParent'=>{ 'rq'=>qq(select s.serviceid from services s inner join services_links sl on s.serviceid=sl.servicedownid where s.name regexp concat('^',?,'( \\\\([${rxZOPfxs}][0-9]+\\\\))?\$') and sl.serviceupid=?      ), },
          'getSvcByNameUnderRoot'=>{ 'rq'=>qq(select s.serviceid from services s left  join services_links sl on s.serviceid=sl.servicedownid where s.name regexp concat('^',?,'( \\\\([${rxZOPfxs}][0-9]+\\\\))?\$') and sl.serviceupid is null), },
          'renSvcByName'=>{ 	'rq'=>qq(update services set name=? where name=?),					},
          'renSvcByID'	=>{ 	'rq'=>qq(update services set name=? where serviceid=?),					},
          'unlinkSvc'	=>{	'rq'=>qq(delete from services_links where serviceupid=? and servicedownid=?),		},
          'algochgSvc'	=>{	'rq'=>qq(update services set algorithm=? where serviceid=?),				},
          'checkHostEnabled'=>{	'rq'=>qq(select if(maintenance_status=1 or status=1,0,1) flHostMonStatus from hosts where hostid=?)	},
);

my $flInitSuccess;

sub init {
 my ($slf,$dbh)=@_;
 do { $dbh=$slf; $slf=undef } if ref($slf) eq 'DBI::db';
 return undef unless ($dbh=$dbh || zbx_get_dbhandle);
 $_->{'st'}=$dbh->prepare($_->{'rq'}) for values %sql_;

 for my $zo (values %ltr2zobj) {
  my @zoNameAttrs=(ref($zo->{'name'}{'attr'}) eq 'ARRAY')?join(','=>@{$zo->{'name'}{'attr'}}):($zo->{'name'}{'attr'});
  for my $what ('name','zobj') {
   my $query=$zo->{$what}{'query'}=sprintf(
    'SELECT %s FROM %s WHERE %s=?',
     join(','=>@zoNameAttrs,$what eq 'zobj'?($zo->{'id_attr'}):()),
     @{$zo}{'table','id_attr'},
   );
   $zo->{$what}{'st'}=$dbh->prepare($query);
  }
  $zo->{'name'}{'get'}=sub {
   $zo->{'name'}{'st'}->execute(shift);
   my @res=map {utf8::decode($_); $_} @{$zo->{'name'}{'st'}->fetchall_arrayref([])->[0]};
   $zo->{'name'}{'fmt'}?
    sprintf($zo->{'name'}{'fmt'}, @res)
                       :
    join(' '=>@res)    ;
  };
  $zo->{'zobj'}{'get'}=sub {
   $zo->{'zobj'}{'st'}->execute(shift);
   return {} unless my $zobj=$zo->{'zobj'}{'st'}->fetchall_arrayref({})->[0];
   utf8::decode($zobj->{$_}) for @zoNameAttrs;
   return $zobj;
  };
  $zo->{'name'}{'update'}=sub {
   my ($objid,$newName)=@_;
   my $stRename=$dbh->prepare(sprintf('UPDATE %s SET %s=? WHERE %s=?', $zo->{'table'}, (ref($zo->{'name'}{'attr'})?$zo->{'name'}{'attr'}[0]:$zo->{'name'}{'attr'}), $zo->{'id_attr'}));
   $stRename->execute($newName, $objid);
  };
  my $st=$dbh->prepare(sprintf('SELECT 1 FROM %s WHERE %s=?', @{$zo}{'table','id_attr'}));
  $zo->{'check'}{'exists'}=sub {
   return undef unless $_[0]=~/^\d{1,10}$/;
   $st->execute(shift);
   $st->fetchrow_array()
  };
 } 
 $flInitSuccess=1;
}

sub chkITServiceExists {
 $ltr2zobj{'s'}{'check'}{'exists'}->(shift);
}

sub getITServiceChildren {
 my ($svcid,$flResolveZOName)=@_;
 return undef if $svcid and $svcid=~/[^\d]/;
 my $st=$svcid?
  do {
   $sql_{'getSvcChildren'}{'st'}->execute($svcid);
   $sql_{'getSvcChildren'}{'st'}
  }                 :
  do {
   $sql_{'getRootSvcChildren'}{'st'}->execute();
   $sql_{'getRootSvcChildren'}{'st'}
  }; 
 return [map { my $chldSvc=$_; utf8::decode($chldSvc->{'name'}); doITServiceAddZOAttrs($chldSvc,$flResolveZOName) } @{$st->fetchall_arrayref({})}];
}

sub doDeleteITService {
 my $serviceid=shift;
 my $NSvcPerStep=shift || 30;
 sub getSvcDeps {
  my $svcid=shift;
  (map getSvcDeps($_->{'serviceid'}), @{zbx('service.get',{'serviceids'=>$svcid,'selectDependencies'=>['serviceid'],'output'=>['serviceid']},{'flDebug'=>0})->[0]{'dependencies'}}),$svcid;
 }
 my @deps=getSvcDeps($serviceid);
 zbx('service.deletedependencies',\@deps);
 zbx('service.delete',\@deps);
}

sub doMoveITService {
 my ($what2mv,$where2place)=@_;
 $sql_{'mvSvc'}{'st'}->execute($where2place,$what2mv);
}

sub zobjFromSvcName { 
 if (ref $_[0] eq 'SCALAR') {
  ${$_[0]}=~s%${rxZOSfx}%%;
  return wantarray?($2,$3):$1
 } else {
  return ($_[0]=~$rxZOSfx)[wantarray?(1,2):(0)]  
 }
}

sub doITServiceAddZOAttrs {
 my ($svc,$flResolveZOName)=@_;
 return undef unless ref($svc) eq 'HASH' and exists($svc->{'name'}) and exists($svc->{'serviceid'});
 return $svc unless $svc->{'name'}=~s%${rxZOSfx}%% and my ($zoltr, $oid)=($2,$3);
 return $svc unless my $hndlZO=$ltr2zobj{$zoltr} and chkZObjExists($zoltr.$oid);
 my $zotype=$hndlZO->{'otype'};
 @{$svc}{'ztype','zobjid'}=($zotype,$oid,$oid);
 unless ($flResolveZOName) {
  $svc->{$hndlZO->{'id_attr'}}=$oid;
 } else {
  $svc->{$zotype}=$hndlZO->{'zobj'}{'get'}->($oid);
 }
 return $svc;
}

sub doRenameITService {
 my ($from,$to)=@_;
 my $flFromIsName=$from=~m/[^\d]/;
 unless ($flFromIsName) {
  return {'error'=>'No such IT Service'} unless my $svcName=$ltr2zobj{'s'}{'name'}{'get'}->($from);
  if (my $zoSfx=zobjFromSvcName($svcName) and !zobjFromSvcName($to)) {
   $to.=' '.$zoSfx;
  }
 }
 $sql_{'renSvcBy'.($flFromIsName?'Name':'ID')}{'st'}->execute($to,$from);
}

sub doSymLinkITService {
 my @svcids=@_;
 return undef unless @_>1;
 my $where2link=pop @svcids;
 for my $what2link (@svcids) {
  zbx('service.adddependencies',{'soft'=>1,'serviceid'=>$where2link,'dependsOnServiceid'=>$what2link});
 }
}

sub doUnlinkITService {
 my ($where,$what)=@_;
 $sql_{'unlinkSvc'}{'st'}->execute($where,$what);
}

sub setAlgoITService {
 my ($serviceid,$newalgo)=@_;
 $sql_{'algochgSvc'}{'st'}->execute($newalgo,$serviceid);
}

sub doAssocITService {
 my ($svcid,$zobjid)=@_;
 return {'error'=>'No such Zabbix object: '.$zobjid} 	unless chkZObjExists($zobjid);
 return {'error'=>'No such IT Service: '.$svcid}   	unless $ltr2zobj{'s'}{'check'}{'exists'}->($svcid);
 my $svcName=$ltr2zobj{'s'}{'name'}{'get'}->($svcid);
 my $ltrs=join(''=>keys %ltr2zobj);
 $svcName=~s%\s*\([${ltrs}]\d{1,10}\)$%%;
 $svcName.=' ('.$zobjid.')';
 $ltr2zobj{'s'}{'name'}{'update'}->($svcid,$svcName);
}

sub doDeassocITService {
 my $svcid=shift;
 return {'error'=>'No such ITService'} unless my $svcName=$ltr2zobj{'s'}{'name'}{'get'}->($svcid);
 return {'result'=>($svcName=~s%${rxZOSfx}%%?$ltr2zobj{'s'}{'name'}{'update'}->($svcid,$svcName):-1)};
}

sub getServiceIDsByNames {
 return undef unless @_;
 map {
  if (/[^\d]/) {
   (my $st=$sql_{'getSvcByName'}{'st'})->execute($_);
   my @r=@{$st->fetchall_arrayref({})};
   return undef if @r>1 or !@r;
   $r[0]{'serviceid'}+0;
  } else {
   $_+0
  }
 } @_;
}

sub chkZObjExists {
 my $zobjid=shift;
 my $ltrs=join(''=>keys %ltr2zobj);
 return () unless my ($objType,$objID)=$zobjid=~m/^([${ltrs}])(\d{1,10})$/;
 return $ltr2zobj{$objType}{'check'}{'exists'}->($objID)?($objType,$objID):();
}

sub genITServicesTree  {
 my $parentSvc=shift;
 # No serviceid defined for parent node, we cant do anymore
 return undef   unless defined( my $parSvcID=$parentSvc->{'serviceid'});
 my $childNodes=$parentSvc->{'nodes'};
 # No child nodes, exit normally 
 return 1 		unless defined $childNodes and ref($childNodes) eq 'HASH' and %{$childNodes}; 
 my $errc=0;
 my @out;
 while (my ($svcName,$svcNode)=each %{$childNodes}) {
  my $svcid=$svcNode->{'serviceid'};  
  if ($svcNode->{'serviceid'}||=do {
   my %svcSettings=(
    'algorithm'	=>	SLA_ALGO_ALL_FOR_PROBLEM,
    'showsla'	=>	SHOW_SLA_CALC,
    'goodsla'	=>	DEFAULT_GOOD_SLA,
    'sortorder'	=>	0,
   );
   # Hint: 'triggerid' is absent in %svcSettings, so we need to explicitly put it in @k
   my @k=(
    'triggerid',
    grep defined($svcSettings{$_}), keys %{$svcNode}
   );
   @svcSettings{@k}=@{$svcNode}{@k} if @k;   
   eval { 
    zbx('service.create',{
     'name'=>$svcName,
     'parentid'=>$parSvcID,
     %svcSettings
    })->{'serviceids'}[0] 
   }
  }) {
   push @out, ( $svcNode->{'serviceid'}=>{'state'=>0,'msg'=>$svcid?'Exists':'Created'} ),
              ( $svcNode->{'nodes'}?genITServicesTree($svcNode):() );
  } else {
   push @out, ( $svcNode->{'serviceid'}=>{'state'=>1, 'msg'=>zbx_last_err()} )
  }
 } # <- for each child node
 return @out;
} # <- sub genITServicesTree($parentNode)

sub getITServiceAPI {
 my ($svcParent,$serviceGetPars)=@_;
 my $childSvcs=zbx('service.get',{%{$serviceGetPars},'serviceids'=>$svcParent->{'serviceid'},'selectDependencies'=>['serviceid']});
 return undef unless ref($childSvcs) eq 'ARRAY' and @{$childSvcs};
 for my $refDep (map { map \$_, @{$_->{'dependencies'}} } grep {!$_->{'triggerid'} and @{$_->{'dependencies'}}} @{$childSvcs}) {
  $$refDep=getITServiceAPI($$refDep,$serviceGetPars);
  delete $$refDep->{'triggerid'} unless $$refDep->{'triggerid'};
 }
 return scalar($#{$childSvcs}?$childSvcs:$childSvcs->[0])
}

sub getITServiceIDByName {
 my @names=ref($_[0]) eq 'ARRAY'?@{$_[0]}:do { my @snh=split /\//,$_[0]; shift @snh if $snh[0] eq ''; @snh };
 my $parSvcID=$_[1];
# say "names=".join(','=>@names)." parsvc=".($parSvcID?$parSvcID:'<ROOT>');
 my $st=$sql_{'getSvcByName'.($parSvcID?'AndParent':'UnderRoot')}{'st'};
 $st->execute(scalar(shift @names),($parSvcID?$parSvcID:()));
 return undef unless my $svc=$st->fetchall_arrayref([])->[0];
 return @names?getITServiceIDByName(\@names,$svc->[0]):$svc->[0];
}

sub getITServicesAssociatedWith {
 my $zobjid=shift;
 $sql_{'getSvcByZOExt'}{'st'}->execute($zobjid);
 return $sql_{'getSvcByZOExt'}{'st'}->fetchall_arrayref({});
}

my %cacheSvcTree;
sub getITService {
 return undef unless $flInitSuccess;
 my $svc=shift;
 unless (ref($svc)) {
  my $stGetSvc=$sql_{'getSvc'}{'st'};
  $stGetSvc->execute($svc);
  $svc=$stGetSvc->fetchall_arrayref({})->[0];
  return undef unless $svc;
  %cacheSvcTree=();
 }
 my $serviceid=$svc->{'serviceid'};
 return undef if $cacheSvcTree{$serviceid}{'rflag'};
 return $cacheSvcTree{$serviceid}{'obj'} if $cacheSvcTree{$serviceid}{'obj'};
 my ($zoType,$zoID)=zobjFromSvcName($svc->{'name'});
 $cacheSvcTree{$serviceid}{'rflag'}=1;
 utf8::decode($svc->{'name'});
 if ($svc->{'triggerid'}) {
  $svc->{'ztype'}='trigger';
  $svc->{'zobjid'}=$svc->{'triggerid'};
  my $stGetTrg=$sql_{'getTrg'}{'st'};
  $stGetTrg->execute($svc->{'triggerid'});
  my $trg=$stGetTrg->fetchall_arrayref({})->[0];
  $svc->{'lostfunk'}=($trg->{'priority'}-1)/4 if $trg->{'value'} and !$trg->{'status'} and $trg->{'priority'}>1;  
 } else {
  if ( my ($zoType,$zoID)=zobjFromSvcName(\$svc->{'name'}) ) {
   if ($zoType eq 't') {
    $svc->{'invalid'}=1;
    return $svc
   }
   if ( defined(my $zoDscrByType=$ltr2zobj{$zoType}) ) {
    $svc->{'ztype'}=$zoDscrByType->{'otype'};
    $svc->{'zobjid'}=$zoID;
    $svc->{$zoDscrByType->{'id_attr'}}=$zoID;
   }
  }
  delete $svc->{'triggerid'};
  if ($zoType eq 'h') {
   $sql_{'checkHostEnabled'}{'st'}->execute($zoID);
   @{$svc}{'disabled','unfinished'}=(1,1) unless $sql_{'checkHostEnabled'}{'st'}->fetchall_arrayref([])->[0][0];
  }
  unless (exists $svc->{'disabled'}) {
   my $stGetDeps=$sql_{'getSvcDeps'}{'st'};
   $stGetDeps->execute($serviceid);
   if ( my @deps=grep { !exists $_->{'invalid'} } map { return undef unless my $t=getITService($_); $t } @{$stGetDeps->fetchall_arrayref({})} ) {
 #   @deps=@deps>1?iterate_as_array(\&getSvc,\@deps):(getSvc($deps[0]));
    if (my @ixTermDeps=grep { !exists $deps[$_]{'unfinished'} } 0..$#deps) {
     my $lostFunK=0;
     my $childLFKWeight=$svc->{'algorithm'}==SLA_ALGO_ALL_FOR_PROBLEM?(1/@ixTermDeps):1;
     $lostFunK+=$_*$childLFKWeight for grep $_, map $deps[$_]{'lostfunk'}, @ixTermDeps;
     $svc->{'lostfunk'}=$lostFunK>1?1:$lostFunK if $lostFunK;
    } else {
     $svc->{'unfinished'}=1;
    }
    $svc->{'dependencies'}=\@deps;
   } else {
    $svc->{'unfinished'}=1;
   }  
  }
 }
 $cacheSvcTree{$serviceid}{'rflag'}=0;
 $cacheSvcTree{$serviceid}{'obj'}=$svc;
}

sub getITService4jsTree {
 my ($svc,@pars)=@_;
 return undef unless $flInitSuccess;
 unless (ref($svc)) {
  my $stGetSvc=$sql_{'getSvc'}{'st'};
  $stGetSvc->execute($svc);
  $svc=$stGetSvc->fetchall_arrayref({})->[0];
  return undef unless $svc;
  %cacheSvcTree=();
 }
 my $serviceid=$svc->{'serviceid'};
 return undef if $cacheSvcTree{$serviceid}{'rflag'};
 return $cacheSvcTree{$serviceid}{'obj'} if $cacheSvcTree{$serviceid}{'obj'};
 $cacheSvcTree{$serviceid}{'rflag'}=1; 
 utf8::decode($svc->{'name'});
 my ($zotype,$zoid);
 if ($svc->{'triggerid'}) {
  $zotype='t';
  $svc->{'ztype'}='trigger';
  $svc->{'zobjid'}=$zoid=$svc->{'triggerid'};
  my $stGetTrg=$sql_{'getTrg'}{'st'};
  $stGetTrg->execute($svc->{'triggerid'});
  my $trg=$stGetTrg->fetchall_arrayref({})->[0];
  $svc->{'lostfunk'}=($trg->{'priority'}-1)/4 if $trg->{'value'} and !$trg->{'status'} and $trg->{'priority'}>1;  
 } else {
  delete $svc->{'triggerid'};
  if ($svc->{'name'}=~s%(?:\s+|^)\(([a-zA-Z])(\d{1,10})\)$%% and defined $ltr2zobj{$1}) {
   ($zotype,$zoid)=($1,$2);
   $svc->{'ztype'}=$ltr2zobj{$zotype}{'otype'};
   $svc->{'zobjid'}=$zoid;
   $svc->{$ltr2zobj{$zotype}{'id_attr'}}=$zoid;
  }  
  my $stGetDeps=$sql_{'getSvcDeps'}{'st'};
  $stGetDeps->execute($serviceid);
# grep {! exists($_->{'unfinished'}) }
  if ( my @deps=map { return undef unless my $t=getITService4jsTree($_,@pars,$serviceid); $t } @{$stGetDeps->fetchall_arrayref({})} ) {
   my $lostFunK=0;
   my $childLFKWeight=$svc->{'algorithm'}==2?(1/@deps):1;
   $lostFunK+=$_*$childLFKWeight for grep $_, map $_->{'lostfunk'}, @deps;
   $svc->{'lostfunk'}=$lostFunK>1?1:$lostFunK if $lostFunK;
   $svc->{'children'}=\@deps;
  } else {
   $svc->{'unfinished'}=1;
  }
 }
 $svc->{'text'}=sprintf('%s [%d]',@{$svc}{'name','serviceid'});
 $svc->{'data'}={
  'algo'=>$svc->{'algorithm'},
 };
 if (defined $svc->{'ztype'}) {
  @{$svc->{'data'}}{map 'ZO_'.$_,qw(type id name)}=(ucfirst($svc->{'ztype'}), $zoid, $ltr2zobj{$zotype}{'name'}{'get'}->($zoid));
 }
 $svc->{'a_attr'}={
  'title'=>join('; ' => 
    sprintf('Service: id=%s algo=%s',@{$svc}{qw(serviceid algorithm)}),
    defined($svc->{'ztype'})?( 
     sprintf('%s: id=%s name=%s', @{$svc->{'data'}}{map 'ZO_'.$_,qw(type id name)})
    ):()
  ),
 };
 $svc->{'id'}=join '/' => @pars, $svc->{'serviceid'};
 $cacheSvcTree{$serviceid}{'rflag'}=0;
 $cacheSvcTree{$serviceid}{'obj'}=$svc; 
}

sub getITSCache {
 \%cacheSvcTree;
}

sub getAllITServiceDeps {
 sub svcDepsClean {
  my $svc=shift;
  return { map {$_=>$svc->{$_}} grep {$_ ne 'dependencies'} keys %{$svc} }
 }
 sub getDepsRecursive {
  my $svc=shift;
  return {} unless ref $svc;
  return svcDepsClean($svc) unless defined($svc->{'dependencies'}) and @{$svc->{'dependencies'}};
  return (
    svcDepsClean($svc),
    map getDepsRecursive($_), @{$svc->{'dependencies'}}
  )
 }
 getDepsRecursive(getITService(shift));
}

sub getITServiceDepsByType {
 my ($rootSvcID,$typeLetter)=@_;
 return {'error'=>'Wrong parameters passed'} unless $ltr2zobj{$typeLetter} and $rootSvcID=~m/^\d{1,10}$/;
 return {'error'=>'Base ITService with the specified ID not found'} unless !$rootSvcID or chkITServiceExists($rootSvcID);
 my ($ztype,$idattr)=@{$ltr2zobj{$typeLetter}}{qw(otype id_attr)};
 return {'error'=>'You must properly initialize Zabbix API before passing base serviceid=0 to getITServiceDepsByType'} unless $rootSvcID or zbx_api_url;
 my @svcs=$rootSvcID
  ?
 grep {defined($_->{'ztype'}) and $_->{'ztype'} eq $ztype} getAllITServiceDeps($rootSvcID)
  :
 grep defined $_, map {
  $_->{'name'}=~s%^(.+)\s+\(${typeLetter}(\d+)\)$%$1%
   ?do {
     $_->{$idattr}=$2; $_
    }
   :undef
 } @{zbx('service.get', {'search'=>{'name'=>"*(${typeLetter}*)"},'output'=>['name']})};
}

1;
