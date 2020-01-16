#
# @(#)$Id$
#
#
package CRL;
use strict;
require OSSL and import OSSL unless defined &OSSL::new;
use vars qw/ $log $cnf /;

# Syntax:
#   CRL->new( [name [,data]] );
#   CRL->setName( name);
#   CRL->setData( datablob ); # load a CRL in PEM format or bails out
#   CRL->verify( cafilelist ); # returns path to CA or undef if verify failed
#
#
sub new { 
  my $obref = {}; bless $obref;
  my $self = shift;
  $self = $obref;
  my $name = shift;
  my $data = shift;

  $self->{"name"} = "unknown";

  $self->setName($name) if $name;
  $self->setData($data) if $data;

  return $self;
}

sub setName($$) {
  my $self = shift or die "Invalid invocation of CRL::setName\n";
  my $name = shift;
  return 0 unless $name;

  $self->{"name"} = $name;
  return 1;
}

sub setData($$) {
  my $self = shift or die "Invalid invocation of CRL::setData\n";
  my $data = shift;
  my $pemdata = undef;
  my $errormsg;
  my $openssl = OSSL->new() or $::log->err("OpenSSL not found") and return 0;

  # try to recognise data type and normalise to PEM string
  # but extract only the first blob of PEM (so max one CRL per data object)
  #
  if ( $data =~ 
    /(^-----BEGIN X509 CRL-----\n[^-]+\n-----END X509 CRL-----$)/sm ) {
    $pemdata = $1;
  } elsif ( substr($data,0,1) eq "0" ) { # looks a bit like an ASN.1 SEQ
    ($pemdata,$errormsg) = 
      $openssl->Exec3($data, qw/ crl -inform DER -outform PEM / );
    $pemdata or 
      $::log->warn("Apparent DER data for",$self->{"name"},"not recognised")
      and return 0;
  } else {
    $::log->warn("CRL data for",$self->{"name"},"not recognised");
    return 0;
  }

  # extract other data from the pem blob with openssl
  (my $statusdata,$errormsg) = 
    $openssl->Exec3($pemdata, qw/ crl 
      -noout -issuer -sha1 -fingerprint -lastupdate -nextupdate -hash/);
  defined $statusdata or do {
    ( my $eline = $errormsg ) =~ s/\n.*//sgm;
    $::log->warn("Unable to extract CRL data for",$self->{"name"},$eline);
    return 0;
  };
  $statusdata =~ /(?:^|\n)SHA1 Fingerprint=([^\n]+)\n/ and 
    $self->{"sha1fp"} = $1;
  $statusdata =~ /(?:^|\n)issuer=([^\n]+)\n/ and 
    $self->{"issuer"} = $1;
  $statusdata =~ /(?:^|\n)lastUpdate=([^\n]+)\n/ and 
    $self->{"lastupdatestr"} = $1;
  $statusdata =~ /(?:^|\n)nextUpdate=([^\n]+)\n/ and 
    $self->{"nextupdatestr"} = $1;
  $statusdata =~ /(?:^|\n)([0-9a-f]{8})\n/ and 
    $self->{"hash"} = $1;

  $self->{"nextupdatestr"} and 
    $self->{"nextupdate"} = $openssl->gms2t($self->{"nextupdatestr"});
  $self->{"lastupdatestr"} and 
    $self->{"lastupdate"} = $openssl->gms2t($self->{"lastupdatestr"});

  #$self->{"nextupdate"} = time - 200;
  #$self->{"lastupdate"} = time + 200;

  $self->{"data"} = $data;
  $self->{"pemdata"} = $pemdata;

  return 1;
}

sub getLastUpdate($) {
  my $self = shift or die "Invalid invocation of CRL::getLastUpdate\n";
  return $self->{"lastupdate"} || undef;
}

sub getNextUpdate($) {
  my $self = shift or die "Invalid invocation of CRL::getNextUpdate\n";
  return $self->{"nextupdate"} || undef;
}

sub getAttribute($$) {
  my $self = shift or die "Invalid invocation of CRL::getAttribute\n";
  my $key = shift;
  return $self->{$key} || undef;
}

sub getPEMdata($) {
  my $self = shift or die "Invalid invocation of CRL::getPEMdata\n";
  $self->{"pemdata"} or 
    $::log->err("Attempt to extract PEM data from bad CRL object",
                ($self->{"name"}||"unknown")) and 
    return undef;
  return $self->{"pemdata"};
}

sub verify($@) {
  my $self = shift or die "Invalid invocation of CRL::verify\n";
  my $openssl = OSSL->new() or $::log->err("OpenSSL not found") and return 0;
  $self->{"pemdata"} or 
    $::log->err("verify called on empty data blob") and return 0;
  
  my @verifyStatus = ();
  # openssl crl verify works against a single CA and does not need a 
  # full chain to be present. That suits us file (checked with OpenSSL 
  # 0.9.5a and 1.0.0a)

  my $verifyOK;
  foreach my $cafile ( @_ ) {
    -e $cafile or 
      $::log->err("CRL::verify called with nonexistent CA file $cafile") and 
      next;

    my ($dataout,$dataerr) = 
      $openssl->Exec3($self->{"pemdata"}, qw/crl -noout -CAfile/,$cafile);
    $dataerr and $dataout .= $dataerr;
    $dataout =~ /verify OK/ and $verifyOK = $cafile and last;
  }
  $verifyOK or push @verifyStatus, "CRL signature failed";
  $verifyOK and 
    $::log->verb(4,"Verified CRL",$self->{"name"},"against $verifyOK");

  $self->{"nextupdate"} or
    push @verifyStatus, "CRL nextUpdate determination failed";
  $self->{"lastupdate"} or
    push @verifyStatus, "CRL lastUpdate determination failed";
  if ( $self->{"nextupdate"} and $self->{"nextupdate"} < time ) {
    push @verifyStatus, "CRL has nextUpdate time in the past";
  }
  if ( $self->{"lastupdate"} and $self->{"lastupdate"} > time ) {
    push @verifyStatus, "CRL has lastUpdate time in the future";
  }

  return @verifyStatus;
}


1;
