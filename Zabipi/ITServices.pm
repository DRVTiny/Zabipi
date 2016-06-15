package Monitoring::Zabipi::ITServices;
use Monitoring::Zabipi qw(zbx);
use v5.14.1;
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
use Exporter qw(import);
our @EXPORT_OK=qw(doDeleteITService genITServicesTree getITService getAllITServiceDeps doMoveITService getServiceIDsByNames doSymLinkITService chkZObjExists doAssocITService);
our @EXPORT=qw(doDeleteITService doMoveITService doRenameITService getITService getITService4jsTree genITServicesTree getServiceIDsByNames doSymLinkITService doUnlinkITService getITSCache setAlgoITService chkZObjExists doAssocITService doDeassocITService);
use DBI;
use Data::Dumper;

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
my $rxZOPfxs=join ''=>keys %ltr2zobj;
my $rxZOSfx=qr/\s*(\(([${rxZOPfxs}])(\d{1,10})\))$/;
my %sql_=(
          'getSvcDeps'=>{
                                'rq'=>qq(select s.serviceid,s.name,s.algorithm,s.triggerid from services s inner join services_links l on s.serviceid=l.servicedownid where l.serviceupid=?),
          },
          'getSvc'=>	{ 	'rq'=>qq(select serviceid,name,algorithm,triggerid from services where serviceid=?), 	},
          'getTrg'=>	{ 	'rq'=>qq(select priority,value,status from triggers where triggerid=?),			},
          'mvSvc'=>	{ 	'rq'=>qq(update services_links set serviceupid=? where servicedownid=?), 		},
          'getSvcByName'=>{ 	'rq'=>qq(select serviceid from services where name=?),					},
          'renSvcByName'=>{ 	'rq'=>qq(update services set name=? where name=?),					},
          'renSvcByID'	=>{ 	'rq'=>qq(update services set name=? where serviceid=?),					},
          'unlinkSvc'	=>{	'rq'=>qq(delete from services_links where serviceupid=? and servicedownid=?),		},
          'algochgSvc'	=>{	'rq'=>qq(update services set algorithm=? where serviceid=?),				},
);

my $flInitSuccess;

sub init {
 my ($slf,$dbh)=@_;
 $dbh=$slf if ref($slf) eq 'DBI::db';
 $_->{'st'}=$dbh->prepare($_->{'rq'}) for values %sql_;
 for my $zo (values %ltr2zobj) {
  $zo->{'name'}{'query'}=sprintf(
   'SELECT %s FROM %s WHERE %s=?',
    ( (ref($zo->{'name'}{'attr'}) eq 'ARRAY')?join(','=>@{$zo->{'name'}{'attr'}}):$zo->{'name'}{'attr'} ),
    @{$zo}{'table','id_attr'},
  );
  $zo->{'name'}{'st'}=$dbh->prepare($zo->{'name'}{'query'});
  $zo->{'name'}{'get'}=sub {
   $zo->{'name'}{'st'}->execute(shift);
   my @res=map {utf8::decode($_); $_} @{$zo->{'name'}{'st'}->fetchall_arrayref([])->[0]};
   $zo->{'name'}{'fmt'}?
    sprintf($zo->{'name'}{'fmt'}, @res)
                       :
    join(' '=>@res)    ;
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
 ($_[0]=~$rxZOSfx)[wantarray?(1,2):(0)];
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
 $svcName=~s%${rxZOSfx}%%;
 return {'result'=>$ltr2zobj{'s'}{'name'}{'update'}->($svcid,$svcName)};
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
 return undef unless my ($objType,$objID)=$zobjid=~m/^([${ltrs}])(\d{1,10})$/;
 return scalar($ltr2zobj{$objType}{'check'}{'exists'}->($objID));
}

sub genITServicesTree  {
 my $parentSvc=shift;
 # No serviceid defined for parent node, we cant do anymore
 return undef   unless defined( my $parSvcID=$parentSvc->{'serviceid'});
 my $childNodes=$parentSvc->{'nodes'};
 # No child nodes, exit normally 
 return 1 		unless defined $childNodes and ref($childNodes) eq 'HASH' and %{$childNodes}; 
 my $errc=0;
 while (my ($svcName,$svcNode)=each %{$childNodes}) {
  my %svcSettings=(
   'algorithm'	=>	SLA_ALGO_ALL_FOR_PROBLEM,
   'showsla'	=>	SHOW_SLA_CALC,
   'goodsla'	=>	DEFAULT_GOOD_SLA,
   'sortorder'	=>	0,
  );
  my @k=('triggerid',grep defined($svcSettings{$_}),keys %{$svcNode});
  @svcSettings{@k}=@{$svcNode}{@k} if @k;
  if ($svcNode->{'serviceid'}=eval { zbx('service.create',{'name'=>$svcName, 'parentid'=>$parSvcID, %svcSettings})->{'serviceids'}[0] } and defined($svcNode->{'nodes'})) {
   genITServicesTree($svcNode)
  } else {
   $errc++
  }
 } # <- for each child node
 return $errc?undef:0;
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
  if ($svc->{'name'}=~s%(?:\s+|^)\(([a-zA-Z])(\d{1,10})\)$%% and defined $ltr2zobj{$1}) {
   my ($zotype,$zoid)=($1,$2);
   $svc->{'ztype'}=$ltr2zobj{$zotype}{'otype'};
   $svc->{'zobjid'}=$zoid;
   $svc->{$ltr2zobj{$zotype}{'id_attr'}}=$zoid;
  }
  delete $svc->{'triggerid'};
  my $stGetDeps=$sql_{'getSvcDeps'}{'st'};
  $stGetDeps->execute($serviceid);
  if ( my @deps=map { return undef unless my $t=getITService($_); $t } @{$stGetDeps->fetchall_arrayref({})} ) {
#   @deps=@deps>1?iterate_as_array(\&getSvc,\@deps):(getSvc($deps[0]));
   my $lostFunK=0;
   my $childLFKWeight=$svc->{'algorithm'}==2?(1/@deps):1;
   $lostFunK+=$_*$childLFKWeight for grep $_, map $_->{'lostfunk'}, @deps;
   $svc->{'lostfunk'}=$lostFunK>1?1:$lostFunK if $lostFunK;
   $svc->{'dependencies'}=\@deps;
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
  if ( my @deps=map { return undef unless my $t=getITService4jsTree($_,@pars,$serviceid); $t } @{$stGetDeps->fetchall_arrayref({})} ) {
#   @deps=@deps>1?iterate_as_array(\&getSvc,\@deps):(getSvc($deps[0]));
   my $lostFunK=0;
   my $childLFKWeight=$svc->{'algorithm'}==2?(1/@deps):1;
   $lostFunK+=$_*$childLFKWeight for grep $_, map $_->{'lostfunk'}, @deps;
   $svc->{'lostfunk'}=$lostFunK>1?1:$lostFunK if $lostFunK;
   $svc->{'children'}=\@deps;
  }
 }
 $svc->{'text'}=sprintf('%s [%d]',@{$svc}{'name','serviceid'});
 $svc->{'a_attr'}={
  'title'=>join('; ' => 
    'Service: id='.$svc->{'serviceid'}, 
    defined($svc->{'ztype'})?( 
     sprintf('%s: id=%s name=%s', ucfirst($svc->{'ztype'}), $zoid, $ltr2zobj{$zotype}{'name'}{'get'}->($zoid))
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

1;
