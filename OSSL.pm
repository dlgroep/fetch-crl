#
# @(#)$Id$
#
#
package OSSL;
use strict;
use POSIX;
use File::Temp qw/ tempfile /;
use IPC::Open3;
use IO::Select;
use Time::Local;
use vars qw/ $log $cnf $opensslversion /;

# Syntax:
#   OSSL->new( [path] );
#   OSSL->setName( name);

#
sub new { 
  my $obref = {}; bless $obref;
  my $self = shift;
  $self = $obref;
  my $openssl = shift;
  $self->{"openssl"} = "openssl";
  $self->{"openssl"} = $::cnf->{_}->{"openssl"} if $::cnf->{_}->{"openssl"};
  $self->setOpenSSL($openssl) if $openssl;
  $self->{"version"} = undef;
  return $self;
}

sub setOpenSSL($$) {
  my $self = shift or die "Invalid invocation of CRL::setOpenSSL\n";
  my $openssl = shift;
  return 0 unless $openssl;

  $openssl =~ /\// and ! -x "$openssl" or 
    $::log->err("OpenSSL binary $openssl is not executable or does not exist") 
    and return 0;

  $::log->verb(4,"Using OpenSSL at $openssl");
  $self->{"openssl"} = $openssl;
  $self->{"version"} = undef;

  return 1;
}

sub getVersion($) {
  my $self = shift or die "Invalid invocation of CRL::getVersion\n";
  #$self->{"version"} and return $self->{"version"};
  $opensslversion and return $opensslversion;

  my ($data,$errors) = $self->Exec3(undef,qw/version/);
  if ( defined $data ) {
    $data =~ /^OpenSSL\s+([\d\.]+\w)/ or 
      $::log->err("Cannot get OpenSSL version from command: invalid format in $data".($errors?" ($errors)":"")) and
      return undef;

    $self->{"version"} = $1;
    $opensslversion = $self->{"version"};
    return $1;
  } else {
    $::log->err("Cannot get OpenSSL version from command: $errors");
    return undef;
  }
}

sub Exec3select($$@) {
  my $self = shift or die "Invalid invocation of CRL::OpenSSL\n";
  my $datain = shift;
  my ($dataout, $dataerr) = ("",undef);
  my $rc = 0;
  local(*CMD_IN, *CMD_OUT, *CMD_ERR);

  $::log->verb(6,"Executing openssl",@_);
  my $pid = open3(*CMD_IN, *CMD_OUT, *CMD_ERR, $self->{"openssl"}, @_ );

  $SIG{CHLD} = sub {
      $rc = $? >> 8 if waitpid($pid, 0) > 0
  };
  $datain and print CMD_IN $datain;
  close(CMD_IN);
  print STDERR "Printed " . length($datain). " bytes of data\n";

  my $selector = IO::Select->new();
  $selector->add(*CMD_ERR);
  $selector->add(*CMD_OUT);

  my ($char,$cnt);
  while ($selector->count) {
    my @ready = $selector->can_read(1);
    #my @ready = IO::Select->select($selector,undef,undef,1);
    foreach my $fh (@ready) {
        if (fileno($fh) == fileno(CMD_ERR)) {
          $cnt = sysread CMD_ERR, $char, 1;
          if ( $cnt ) { $dataerr .= $char; }
          else { $selector->remove($fh); $dataerr and print STDERR "$dataerr\n";}
        } else {
          $cnt = sysread CMD_OUT, $char, 1;
          if ( $cnt ) { $dataout .= $char; }
          else { $selector->remove($fh); $dataout and print STDERR "$dataout\n"; }
        }
        $selector->remove($fh) if eof($fh);
    }
  }
  close(CMD_OUT);
  close(CMD_ERR);

  if ( $rc >> 8 ) {
    $::log->warn("Execute openssl " . $ARGV[0] . " failed: $rc");
    (my $errmsg = $dataerr) =~ s/\n.*//sgm;
    $::log->verb(6,"STDERR:",$errmsg);
    return undef unless wantarray;
    return (undef,$dataerr);
  }
  return $dataout unless wantarray;
  return ($dataout,$dataerr);
}

sub Exec3pipe($$@) {
  my $self = shift or die "Invalid invocation of CRL::OpenSSL\n";
  my $datain = shift;
  my ($dataout, $dataerr) = ("",undef);
  my $rc = 0;
  local(*CMD_IN, *CMD_OUT, *CMD_ERR);

  $::log->verb(6,"Executing openssl",@_);

  my ($tmpfh,$tmpname);
  $datain and do {
   ($tmpfh,$tmpname) = tempfile("fetchcrl3.XXXXXX", DIR=>'/tmp', UNLINK=>1);
   $|=1;
   print $tmpfh $datain;
   close $tmpfh;
   push @_, "-in", $tmpname;
   select undef,undef,undef,0.01;
  };

  $|=1;

  my $pid = open3( *CMD_IN, *CMD_OUT, *CMD_ERR, $self->{"openssl"}, @_ );

  # allow delay for child to startup - but will hang on many older platforms
  select undef,undef,undef,0.15;

  $SIG{CHLD} = sub {
      $rc = $? >> 8 if waitpid($pid, 0) > 0
  };

  #close(CMD_IN);
  CMD_OUT->autoflush;
  CMD_ERR->autoflush;

  my $selector = IO::Select->new();
  $selector->add(*CMD_ERR, *CMD_OUT);

  while (my @ready = $selector->can_read(0.01)) {
    foreach my $fh (@ready) {
        if (fileno($fh) == fileno(CMD_ERR)) {$dataerr .= scalar <CMD_ERR>}
        else                                {$dataout .= scalar <CMD_OUT>}
        $selector->remove($fh) if eof($fh);
    }
  }
  close(CMD_OUT);
  close(CMD_ERR);
  $tmpname and unlink $tmpname;

  if ( $rc >> 8 ) {
    $::log->warn("Execute openssl " . $ARGV[0] . " failed: $rc");
    (my $errmsg = $dataerr) =~ s/\n.*//sgm;
    $::log->verb(6,"STDERR:",$errmsg);
    return undef unless wantarray;
    return (undef,$dataerr);
  }
  return $dataout unless wantarray;
  return ($dataout,$dataerr);
}


sub Exec3file($$@) {
  my $self = shift or die "Invalid invocation of CRL::OpenSSL\n";
  my $datain = shift;
  my ($dataout, $dataerr) = ("",undef);
  my $rc = 0;
  local(*CMD_IN, *CMD_OUT, *CMD_ERR);

  $::log->verb(6,"Executing openssl",@_);

  my ($tmpin,$tmpinname);
  my ($tmpout,$tmpoutname);
  my ($tmperr,$tmperrname);

  my $tmpdir = $::cnf->{_}->{exec3tmpdir} || $ENV{"TMPDIR"} || '/tmp';

  $|=1;
  $datain and do {
   ($tmpin,$tmpinname) = tempfile("fetchcrl3in.XXXXXX", 
                                  DIR=>$tmpdir, UNLINK=>1);
   print $tmpin $datain;
   close $tmpin;
  };
  ($tmpout,$tmpoutname) = tempfile("fetchcrl3out.XXXXXX", 
                                   DIR=>$tmpdir, UNLINK=>1);
  ($tmperr,$tmperrname) = tempfile("fetchcrl3out.XXXXXX", 
                                   DIR=>$tmpdir, UNLINK=>1);

  my $pid = fork();

  defined $pid or
    $::log->warn("Internal error, fork for openssl failed: $!") and
    return undef;

  if ( $pid == 0 ) { # I'm a kid
    close STDIN;
    if ( $tmpinname ) {
      open STDIN, "<", $tmpinname or 
        die "Cannot open tempfile $tmpinname again $!\n";
    } else {
      open STDIN, "<", "/dev/null" or 
        die "Cannot open /dev/null ??? $!\n";
    }
    close STDOUT;
    if ( $tmpoutname ) {
      open STDOUT, ">", $tmpoutname or 
        die "Cannot open tempfile $tmpoutname again $!\n";
    } else {
      open STDOUT, ">", "/dev/null" or 
        die "Cannot open /dev/null ??? $!\n";
    }
    close STDERR;
    if ( $tmpoutname ) {
      open STDERR, ">", $tmperrname or 
        die "Cannot open tempfile $tmperrname again $!\n";
    } else {
      open STDERR, ">", "/dev/null" or 
        die "Cannot open /dev/null ??? $!\n";
    }
    exec $self->{"openssl"}, @_;
  }
  $rc = $? >> 8 if waitpid($pid, 0) > 0;

  { local $/; $dataout = <$tmpout>; };
  { local $/; $dataerr = <$tmperr>; };

  $tmpinname and unlink $tmpinname;
  $tmpoutname and unlink $tmpoutname;
  $tmperrname and unlink $tmperrname;

  if ( $rc >> 8 ) {
    $::log->warn("Execute openssl " . $ARGV[0] . " failed: $rc");
    (my $errmsg = $dataerr) =~ s/\n.*//sgm;
    $::log->verb(6,"STDERR:",$errmsg);
    return undef unless wantarray;
    return (undef,$dataerr);
  }
  return $dataout unless wantarray;
  return ($dataout,$dataerr);
}

sub Exec3($@) {
  my $self = shift;

  grep /^pipe$/, $::cnf->{_}->{exec3mode}||"" and return $self->Exec3pipe(@_);
  grep /^select$/, $::cnf->{_}->{exec3mode}||"" and return $self->Exec3select(@_);
  return $self->Exec3file(@_); # default
}

sub gms2t($$) {
  my $self = shift;
  my ( $month, $mday, $htm, $year, $tz ) = split(/\s+/,$_[0]);
  die "OSSL::gms2t: cannot hangle non GMT output from OpenSSL\n" 
    unless $tz eq "GMT";

  my %mon=("Jan"=>0,"Feb"=>1,"Mar"=>2,"Apr"=>3,"May"=>4,"Jun"=>5,
           "Jul"=>6,"Aug"=>7,"Sep"=>8,"Oct"=>9,"Nov"=>10,"Dec"=>11);

  my ( $hrs,$min,$sec ) = split(/:/,$htm);
  my $gmt = timegm($sec,$min,$hrs,$mday,$mon{$month},$year);

  #print STDERR ">>> converted $_[0] to $gmt\n";
  return $gmt;
}


1;
