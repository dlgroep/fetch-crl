#
# @(#)$Id$
#
# ###########################################################################
#
# Fetch-CRL3 logging support
package FCLog;
use Sys::Syslog;

# Syntax:
#   $log = CL->new( [outputmode=qualified,cache,direct,syslog] )
#   $log->destadd( destination [,facility] )
#   $log->destremove ( destination )
#   $log->setverbose( level )
#   $log->setdebug( level )
#   $log->setwarnings( 0|1 )
#   $log->debug( level, message ...)
#   $log->verb( level, message ...)
#   $log->warn( level, message ...)
#   $log->err( level, message ...)
#   $log->clear( )
#   $log->flush( )
#   $log->exitstatus( )
#
sub new { 
  my $self = shift;
  my $obref = {}; bless $obref;
  $obref->{"debug"} = 0;
  $obref->{"verbose"} = 0;
  $obref->{"messagecache"} = ();
  $obref->{"warnings"} = 1;
  $obref->{"errors"} = 1;
  $obref->{"rcmode"} = 1;
  $obref->{"warncount"} = 0;
  $obref->{"errorcount"} = 0;
  $obref->{"syslogfacility"} = "daemon";

  while ( my $mode = shift ) {
    $obref->destadd($mode);
  }

  return $obref;
}

sub destadd { 
  my $self = shift;
  my $mode = shift;
  my $facility = (shift or $self->{"syslogfacility"});

  return 0 unless defined $mode;

  $self->{"logmode"}{$mode} = 1;
  if ( $mode eq "syslog" ) {
    my $progname = $0;
    $progname =~ s/^.*\///;
    $self->{"syslogfacility"} = $facility;
    openlog($progname,"nowait,pid", $facility);
  }
  return 1;
}

sub destremove {
  my $self = shift;
  my $ok = 1;

  my $mode = shift;
  $self->{"logmode"} = {} and return 1 if (defined $mode and $mode eq "all");
  unshift @_,$mode;

  while ( my $mode = shift ) {
    if ( defined $self->{"logmode"}{$mode} ) {
      closelog() if $mode eq "syslog";
      delete $self->{"logmode"}{$mode};
    } else {
      $ok=0;
    }
  }
  return $ok;
}

sub setverbose {
  my ($self,$level) = @_;
  my $oldlevel = $self->{"verbose"};
  $self->{"verbose"} = 0+$level;
  return $oldlevel;
}

sub getverbose {
  my ($self) = @_;
  return $self->{"verbose"};
}

sub setdebug {
  my ($self,$level) = @_;
  my $oldlevel = $self->{"debug"};
  $self->{"debug"} = $level;
  return $oldlevel;
}

sub getdebug {
  my ($self) = @_;
  return $self->{"debug"};
}

sub setwarnings {
  my ($self,$level) = @_;
  my $oldlevel = $self->{"warnings"};
  $self->{"warnings"} = $level;
  return $oldlevel;
}

sub getwarnings {
  my ($self) = @_;
  return $self->{"warnings"};
}

sub geterrors {
  my ($self) = @_;
  return $self->{"errors"};
}

sub seterrors {
  my ($self,$level) = @_;
  my $oldlevel = $self->{"errors"};
  $self->{"errors"} = $level;
  return $oldlevel;
}

sub getrcmode {
  my ($self) = @_;
  return $self->{"rcmode"};
}

sub setrcmode {
  my ($self,$level) = @_;
  my $oldlevel = $self->{"rcmode"};
  $self->{"rcmode"} = $level;
  return $oldlevel;
}

sub verb($$$) {
  my $self = shift;
  my $level = shift;
  return 1 unless ( $level <= $self->{"verbose"} );
  my $message = "@_";
  $self->output("VERBOSE($level)",$message);
  return 1;
}

sub debug($$$) {
  my $self = shift;
  my $level = shift;
  return 1 unless ( $level <= $self->{"debug"} );
  my $message = "@_";
  $self->output("DEBUG($level)",$message);
  return 1;
}

sub warn($@) {
  my $self = shift;
  return 1 unless ( $self->{"warnings"} );
  $self->{"warningcount"}++;
  my $message = "@_";
  $self->output("WARN",$message);
  return 1;
}

sub err($@) {
  my $self = shift;
  my $message = "@_";
  return 1 unless ( $self->{"errors"} );
  $self->output("ERROR",$message);
  $self->{"errorcount"}++;
  return 1;
}

sub retr_err($@) {
  my $self = shift;
  my $message = "@_";
  return 1 unless ( $self->{"errors"} );
  $self->output("ERROR",$message);
  return 1 unless ( $self->{"rcmode"} );
  $self->{"errorcount"}++;
  return 1;
}

sub output($$@) {
  my ($self,$label,@message) = @_;
  return 0 unless defined $label and @message;

  my $message = join " ",@message;

  print "" . ($label?"$label ":"") . "$message\n"
    if ( defined $self->{"logmode"}{"qualified"} );
  push @{$self->{"messagecache"}},"" . ($label?"$label ":"") . "$message\n"
    if ( defined $self->{"logmode"}{"cache"} );
  print "$message\n"
    if ( defined $self->{"logmode"}{"direct"} );

  if ( defined $self->{"logmode"}{"syslog"} ) {
    my $severity = "LOG_INFO";
    $severity = "LOG_NOTICE" if $label eq "WARN";
    $severity = "LOG_ERR" if $label eq "ERROR";
    $severity = "LOG_DEBUG" if $label =~ /^VERBOSE/;
    $severity = "LOG_DEBUG" if $label =~ /^DEBUG/;
    syslog($severity, "%s", $message);
  }

  return 1;
}

sub clear($) {
  my $self = shift;

  $self->{"messagecache"} = ();
  return 1;
}

sub flush($) {
  my $self = shift;

  foreach my $s ( @{$self->{"messagecache"}} ) {
    print $s;
  }
  $self->{"messagecache"} = ();

  $self->{"errorcount"} and $self->{"errors"} and return 0;
  $self->{"warningcount"} and $self->{"warnings"} and return 1;
  return 1;
}

sub cleanse($) {
  my $self = shift;
  $self->{"messagecache"} = ();
  $self->{"errorcount"} = 0;
  $self->{"warningcount"} = 0;
  $self->{"logmode"} = {};
  return 1;
}


sub exitstatus($) {
  my $self = shift;

  $self->{"errorcount"} and $self->{"errors"} and return 1;
  return 0;
}

1;
