#
# @(#)$Id$
#
# ###########################################################################
#
#
package TrustAnchor;
use strict;
use File::Basename;
use LWP;
require ConfigTiny and import ConfigTiny unless defined &ConfigTiny::new;
require CRL and import CRL unless defined &CRL::new;
require base64 and import base64 unless defined &base64::b64encode;
use vars qw/ $log $cnf /;

sub new { 
  my $obref = {}; bless $obref;
  my $self = shift;
  $self = $obref;
  my $name = shift;

  $self->{"infodir"} = $cnf->{_}->{infodir};
  $self->{"suffix"} = "info";

  $self->loadAnchor($name) if defined $name;

  return $self;
}

sub saveLogMode($) {
  my $self = shift;
  return 0 unless defined $self;
  $self->{"preserve_warnings"} = $::log->getwarnings;
  $self->{"preserve_errors"} = $::log->geterrors;
  return 1;
}

sub setLogMode($) {
  my $self = shift;
  return 0 unless defined $self;
  $self->{"nowarnings"} and $::log->setwarnings(0);
  $self->{"noerrors"} and $::log->seterrors(0);
  return 1;
}

sub restoreLogMode($) {
  my $self = shift;
  return 0 unless defined $self;
  $self->{"preserve_warnings"} and $self->{"preserve_errors"} or
    die "Internal error: restoreLogMode called without previous save\n";
  $::log->setwarnings($self->{"preserve_warnings"});
  $::log->seterrors($self->{"preserve_errors"});
  return 1;
}

sub getInfodir($$) {
  my $self = shift;
  my ($path) = shift;
  return 0 unless defined $self;

  return $self->{"infodir"};
}

sub setInfodir($$) {
  my $self = shift;
  my ($path) = shift;
  return 0 unless defined $path and defined $self;

  -e $path or 
    $::log->err("setInfodir: path $path does not exist") and return 0;
  -d $path or 
    $::log->err("setInfodir: path $path is not a directory") and return 0;

  $self->{"infodir"} = $path;

  return 1;
}


sub loadAnchor($$) {
  my $self = shift;
  my ($name) = @_;
  return 0 unless defined $name;

  $::log->verb(1,"Initializing trust anchor $name");

  my ( $basename, $path, $suffix) = fileparse($name,('.info','.crl_url'));

  $path = "" if  $path eq "./" and substr($name,0,length($path)) ne $path ;

  $::log->err("Invalid name of trust anchor $name") and return 0 
    unless $basename;

  $self->{"infodir"} = $path if $path ne "";
  $path = $self->{"infodir"} || "";
  $path and $path .= "/" unless $path =~ /\/$/;

  if ( $suffix ) {
    -e $name or 
      $::log->err("Trust anchor data $name not found") and return 0;
  } else { # try and guess which suffix should be used
    ($suffix eq "" and -e $path.$basename.".info" ) and $suffix = ".info";
    ($suffix eq "" and -e $path.$basename.".crl_url" ) and $suffix = ".crl_url";
    $suffix or
      $::log->err("No trust anchor metadata for $basename in '$path'") 
        and return 0;
  }

  if ( $suffix eq ".crl_url" ) {

    $self->{"alias"} = $basename;
    @{$self->{"crlurls"}} = ();
    open CRLURL,"$path$basename$suffix" or
      $::log->err("Error reading crl_url $path$basename$suffix: $!") and return 0;
    my $urllist;
    while (<CRLURL>) {
      /^\s*([^#\n]+).*$/ and my $url = $1 or next;
      $url =~ s/\s*$//; # trailing whitespace is ignored

      $url =~ /^\w+:\/\/.*$/ or 
        $::log->err("File $path$basename$suffix contains a non-URL entry") 
          and close CRLURL and return 0;

      $urllist and $urllist .= "";
      $urllist .= $url;
    }
    close CRLURL;
    push @{$self->{"crlurls"}}, $urllist;
    $self->{"status"} ||= "unknown";

  } else {

    my $info = ConfigTiny->new();
    $info->read( $path . $basename . $suffix ) or 
      $::log->err("Error reading info $path$basename$suffix", $info->errstr) 
        and return 0;

    $info->{_}->{"crl_url"} and $info->{_}->{"crl_url.0"} and 
      $::log->err("Invalid info for $basename: crl_url and .0 duplicate") and 
        return 0;
    $info->{_}->{"crl_url"} and 
      $info->{_}->{"crl_url.0"} = $info->{_}->{"crl_url"};

    # only do something when there is actually a CRL to process
    $info->{_}->{"crl_url.0"} or
      $::log->verb(1,"Trust anchor $basename does not have a CRL") and return 0;

    $info->{_}->{"alias"} or
      $::log->err("Invalid info for $basename: no alias") and 
        return 0;
    $self->{"alias"} = $info->{_}->{"alias"};

    @{$self->{"crlurls"}} = ();
    for ( my $i=0 ; defined $info->{_}{"crl_url.".$i} ; $i++ ) {
      $info->{_}{"crl_url.".$i} =~ s/[;\s]+//g;
      $info->{_}{"crl_url.".$i} =~ s/^\s*([^\s]*)\s*$/$1/;

      $info->{_}{"crl_url.".$i} =~ /^\w+:\/\// or
        $::log->err("File $path$basename$suffix contains a non-URL entry",
          $info->{_}{"crl_url.".$i}) 
          and close CRLURL and return 0;

      push @{$self->{"crlurls"}} , $info->{_}{"crl_url.".$i};
    }

    foreach my $field ( qw/email ca_url status/ ) {
      $self->{$field} = $info->{_}->{$field} if $info->{_}->{$field};
    }

    # status of CA is only knwon for info-file based CAs
    $self->{"status"} ||= "local";

  }

  # preserve basename of file for config and diagnostics
  $self->{"anchorname"} = $basename;

  #
  # set defaults for common values
  foreach my $key ( qw / 
         prepend_url postpend_url agingtolerance 
         httptimeout proctimeout
         nowarnings noerrors nocache http_proxy 
         nametemplate_der nametemplate_pem 
         cadir catemplate statedir
      / ) {
    $self->{$key} = $self->{$key} ||
      $::cnf->{$self->{"alias"}}->{$key} ||
      $::cnf->{$self->{"anchorname"}}->{$key} ||
      $::cnf->{_}->{$key} or delete $self->{$key};
    defined $self->{$key} and do {
      $self->{$key} =~ s/\@ANCHORNAME\@/$self->{"anchorname"}/g;
      $self->{$key} =~ s/\@STATUS\@/$self->{"status"}/g;
      $self->{$key} =~ s/\@ALIAS\@/$self->{"alias"}/g;
    };
  }
  # reversible toggle options
  foreach my $key ( qw / warnings errors cache / ) {
    delete $self->{"no$key"} if $::cnf->{$self->{"alias"}}->{$key} or
      $::cnf->{$self->{"anchorname"}}->{$key} or
      $::cnf->{_}->{$key};
  }
  foreach my $key ( qw / nohttp_proxy noprepend_url nopostpend_url 
                         nostatedir / ) {
    (my $nokey = $key) =~ s/^no//;
    delete $self->{"$nokey"} if $::cnf->{$self->{"alias"}}->{$key} or
      $::cnf->{$self->{"anchorname"}}->{$key} or
      $::cnf->{_}->{$key};
  }

  # overriding of the URLs (alias takes precedence over anchorname
  foreach my $section ( qw / anchorname alias / ) { 
    my $i = 0;
    while ( defined ($::cnf->{$self->{$section}}->{"crl_url.".$i}) ) {
      my $urls;
      ($urls=$::cnf->{$self->{$section}}->{"crl_url.".$i} )=~s/[;\s]+//g;
      ${$self->{"crlurls"}}[$i] = $urls;
      $i++;
    }
  }

  # templates to construct a CA name may still have other separators
  $self->{"catemplate"} =~ s/[;\s]+//g;

  # select only http/https/ftp/file URLs 
  # also transform the URLs using the base patterns and prepend any 
  # local URL patterns (@ANCHORNAME@, @ALIAS@, and @R@)
  for ( my $i=0; $i <= $#{$self->{"crlurls"}} ; $i++ ) {
    my $urlstring = @{$self->{"crlurls"}}[$i];
    my @urls = split(//,$urlstring);
    $urlstring="";
    foreach my $url ( @urls ) {
      if ( $url =~ /^(http:|https:|ftp:|file:)/ ) {
        $urlstring.="" if $urlstring; $urlstring.=$url;
      } else { 
        $::log->verb(0,"URL $url in $basename$suffix unsupported, ignored");
      }
    }
    if ( my $purl = $self->{"prepend_url"} ) {
      $purl =~ s/\@R\@/$i/g;
      $urlstring = join "" , $purl , $urlstring;
    }
    if ( my $purl = $self->{"postpend_url"} ) {
      $purl =~ s/\@R\@/$i/g;
      $urlstring = join "" , $urlstring, $purl;
    }
    if ( ! $urlstring ) {
      $::log->err("No usable CRL URLs for",$self->getAnchorName);
      $self->{"crlurls"}[$i] = "";
    } else {
      $self->{"crlurls"}[$i] = $urlstring;
    }
  }

  return 1;
}

sub getAnchorName($) {
  my $self = shift;
  return ($self->{"anchorname"} || undef);
}

sub printAnchorName($) {
  my $self = shift;
  print "" . ($self->{"anchorname"} || "undefined") ."\n";
}

sub loadCAfiles($) {
  my $self         = shift;
  my $idx = 0;

  # try to find a CA dir, whatever it takes, almost
  my $cadir = $self->{"cadir"} || $self->{"infodir"};

  -d $cadir or 
    $::log->err("CA directory",$cadir,"does not exist") and 
    return 0;

  @{$self->{"cafile"}} = ();
  do {
    my $cafile;
    foreach my $catpl ( split //, $self->{"catemplate"} ) {
      $catpl =~ s/\@R\@/$idx/g;
      -e $cadir.'/'.$catpl and 
        $cafile = $cadir.'/'.$catpl and last;
    }
    defined $cafile or do {
      $idx or do $::log->err("Cannot find any CA for",
                              $self->{"alias"},"in",$cadir);
      return $idx?1:0;
    };
    # is the new one any different from the previous (i.e. is the CA indexed?)
    $#{$self->{"cafile"}} >= 0 and
      $cafile eq $self->{"cafile"}[$#{$self->{"cafile"}}] and return 1;
    push @{$self->{"cafile"}}, $cafile;
    $::log->verb(3,"Added CA file $idx: $cafile");
  } while(++$idx);
  return 0; # you never should come here
}


sub loadState($$) {
  my $self         = shift;
  my $fallbackmode =  shift;

  $self->{"crlurls"} or
    $::log->err("loading state for uninitialised list of CRLs") and return 0;
  $self->{"alias"} or
    $::log->err("loading state for uninitialised trust anchor") and return 0;

  for ( my $i = 0; $i <= $#{$self->{"crlurls"}} ; $i++ ) { # all indices
    if ( $self->{"statedir"} and
         -e $self->{"statedir"}.'/'.$self->{"alias"}.'.'.$i.'.state'
       ) {
      my $state = ConfigTiny->new();
      $state->read($self->{"statedir"}.'/'.$self->{"alias"}.'.'.$i.'.state')
        or $::log->err("Cannot read existing state file",
             $self->{"statedir"}.'/'.$self->{"alias"}.'.$i.state',
             " - ",$state->errstr) and return 0;
      foreach my $key ( keys %{$state->{$self->{"alias"}}} ) {
        $self->{"crl"}[$i]{"state"}{$key} = $state->{$self->{"alias"}}->{$key};
      }
    } 

    # fine, but we should find at least an mtime if at all possible
    # make sure it is there:
             # try to retrieve state from installed files in @output_
             # where the first look-alike CRL will win. NSS databases
             # are NOT supported for this heuristic
    if ( ! defined $self->{"crl"}[$i]{"state"}{"mtime"} ) {
      my $mtime;
      STATEHUNT: foreach my $output ( ( $::cnf->{_}->{"output"},
           $::cnf->{_}->{"output_der"}, $::cnf->{_}->{"output_pem"},
           $::cnf->{_}->{"output_nss"}, $::cnf->{_}->{"output_openssl"}) ) {
        defined $output and $output or next;
        foreach my $file (
              $self->{"nametemplate_der"},
              $self->{"nametemplate_pem"},
              $self->{"alias"}.".r\@R\@",
              $self->{"anchorname"}.".r\@R\@",
            ) {
          next unless $file;
          $file =~ s/\@R\@/$i/g;
          $file = join "/", $output, $file;
          next if ! -e $file;
          $mtime = (stat(_))[9];
          last STATEHUNT;
        }
      }
      $::log->verb(3,"Inferred mtime for",$self->{"alias"},"is",$mtime) if $mtime;
      $self->{"crl"}[$i]{"state"}{"mtime"} = $mtime if $mtime;
    }

    # as a last resort, set mtime to curren time
    $self->{"crl"}[$i]{"state"}{"mtime"} ||= time;

  }
  return 1;
}

sub saveState($$) {
  my $self         = shift;
  my $fallbackmode =  shift;

  $self->{"statedir"} and -d $self->{"statedir"} and -w $self->{"statedir"} or 
    return 0;

  $self->{"crlurls"} or
    $::log->err("loading state for uninitialised list of CRLs") and return 0;
  $self->{"alias"} or
    $::log->err("loading state for uninitialised trust anchor") and return 0;

  # of state, mtime is set based on CRL write in $output and filled there
  for ( my $i = 0; $i <= $#{$self->{"crlurls"}} ; $i++ ) { # all indices
    if ( defined $self->{"statedir"} and
         -d $self->{"statedir"}
       ) {
      my $state = ConfigTiny->new;
      foreach my $key ( keys %{$self->{"crl"}[$i]{"state"}} ) {
        $state->{$self->{"alias"}}->{$key} = $self->{"crl"}[$i]{"state"}{$key};
      }
      $state->write(
        $self->{"statedir"}.'/'.$self->{"alias"}.'.'.$i.'.state' );
      $::log->verb(5,"State saved in",
                     $self->{"statedir"}.'/'.$self->{"alias"}.'.'.$i.'.state');
    } 

  }
  return 1;
}

sub retrieveHTTP($$) {
  my $self = shift;
  my $idx  = shift;
  my $url =  shift;
  my %metadata;
  my $data;

  $url =~ /^(http:|https:|ftp:)/ or die "retrieveHTTP: non-http URL $url\n";

  $::log->verb(3,"Downloading data from $url");
  my $ua = LWP::UserAgent->new;
  $ua->agent('fetch-crl/'.$::cnf->{_}->{version} . ' ('.
             $ua->agent . '; '.$::cnf->{_}->{packager} . ')'
           );
  $ua->timeout($self->{"httptimeout"});
  $ua->use_eval(0);
  if ( $self->{"http_proxy"} ) {
    if ( $self->{"http_proxy"} =~ /^ENV/i ) {
      $ua->env_proxy();
    } else {
      $ua->proxy("http", $self->{"http_proxy"});
    }
  }


  # see with a HEAD request if we can get by with old data
  # but to assess that we need Last-Modified from the previous request
  # (so if the CA did not send that: too bad)
  if ( $self->{"crl"}[$idx]{"state"}{"lastmod"} and
       $self->{"crl"}[$idx]{"state"}{"b64data"}
     ) {
    $::log->verb(4,"Lastmod set to",$self->{"crl"}[$idx]{"state"}{"lastmod"});
    $::log->verb(4,"Attemping HEAD retrieval of $url");

    my $response;
    eval {
     local $SIG{ALRM}=sub{die "timed out after ".$self->{"httptimeout"}."s\n";};
     alarm $self->{"httptimeout"};
     $response = $ua->head($url);
     alarm 0;
    };
    alarm 0; # make sure the alarm stops ticking, regardless of the eval

    if ( $@ ) {
      $::log->verb(2,"HEAD error $url:", $@);
      return undef;
    }

    # try get if head fails anyway
    if ( ( ! $@ ) and
          $response->is_success and 
         $response->header("Last-Modified") ) {
      
      my $lastmod = HTTP::Date::str2time($response->header("Last-Modified"));
      if ( $lastmod == $self->{"crl"}[$idx]{"state"}{"lastmod"}) {
        $::log->verb(4,"HEAD lastmod unchanged, using cache");
        $data = base64::b64decode($self->{"crl"}[$idx]{"state"}{"b64data"});
        %metadata = (
          "freshuntil" => $response->fresh_until(heuristic_expiry=>0)||time,
          "lastmod" => $self->{"crl"}[$idx]{"state"}{"lastmod"} || time,
          "sourceurl" => $self->{"crl"}[$idx]{"state"}{"sourceurl"} || $url
        );
        return ($data,%metadata) if wantarray;
        return $data;

      } elsif ( $lastmod < $self->{"crl"}[$idx]{"state"}{"lastmod"} ) {
        # retrieve again, but print warning abount this wierd behaviour
        $::log->warn("Retrieved HEAD Last-Modified is older than cache: ".
                     "cache invalidated, GET issued");
      }
    }
  }

  # try get if head fails anyway

  my $response;
  eval {
    local $SIG{ALRM}=sub{die "timed out after ".$self->{"httptimeout"}."s\n";};
    alarm $self->{"httptimeout"};
    $response = $ua->get($url);
    alarm 0;
  };
  alarm 0; # make sure the alarm stops ticking, regardless of the eval

  if ( $@ ) {
    chomp($@);
    $::log->verb(0,"Download error $url:", $@);
    return undef;
  }

  if ( ! $response->is_success ) {
    $::log->verb(0,"Download error $url:",$response->status_line);
    return undef;
  }

  $data = $response->content;

  $metadata{"freshuntil"}=$response->fresh_until(heuristic_expiry=>0)||time;
  if ( my $lastmod = $response->header("Last-Modified") ) {
    $metadata{"lastmod"} = HTTP::Date::str2time($lastmod);
  } 
  $metadata{"sourceurl"} = $url;

  return ($data,%metadata) if wantarray;
  return $data;
}

sub retrieveFile($$) {
  my $self = shift;
  my $idx  = shift;
  my $url =  shift;
  $url =~ /^file:\/*(\/.*)$/ or die "retrieveFile: non-file URL $url\n";
  $::log->verb(4,"Retrieving data from $url");

  # for files the previous state does not matter, we retrieve it
  # anyway

  my $data;
  {
    open CRLFILE,$1 or do {
      $! = "Cannot open $1: $!";
      return undef;
    };
    binmode CRLFILE;
    local $/;
    $data = <CRLFILE>;
    close CRLFILE;
  }

  my %metadata;
  $metadata{"lastmod"} = (stat($1))[9];
  $metadata{"freshuntil"} = time;
  $metadata{"sourceurl"} = $url;

  return ($data,%metadata) if wantarray;
  return $data;
}

sub retrieve($) {
  my $self = shift;

  $self->{"crlurls"} or
    $::log->err("Retrieving uninitialised list of CRL URLs") and return 0;

  $::log->verb(2,"Retrieving CRLs for",$self->{"alias"});

  for ( my $i = 0; $i <= $#{$self->{"crlurls"}} ; $i++ ) { # all indices
    my ($result,%response);

    $::log->verb(3,"Retrieving CRL for",$self->{"alias"},"index $i");

    # within the list of CRL URLs for a specific index, all entries
    # are considered equivalent. I.e., if we get one, the metadata will
    # be used for all (like  Last-Modified, and cache control data)

    # if we have a cached piece of fresh data, return that one
    if ( !$self->{"nocache"} and
          ($self->{"crl"}[$i]{"state"}{"freshuntil"} || 0) > time and
          ($self->{"crl"}[$i]{"state"}{"nextupdate"} || time) >= time and
          $self->{"crl"}[$i]{"state"}{"b64data"} ) {
      $::log->verb(3,"Using cached content for",$self->{"alias"},"index",$i);
      $::log->verb(4,"Content dated",
               scalar gmtime($self->{"crl"}[$i]{"state"}{"lastmod"}),
               "valid until",
               scalar gmtime($self->{"crl"}[$i]{"state"}{"freshuntil"}),
               "UTC");
      $result = base64::b64decode($self->{"crl"}[$i]{"state"}{"b64data"});
      %response = (
        "freshuntil" => $self->{"crl"}[$i]{"state"}{"freshuntil"} || time,
        "lastmod" => $self->{"crl"}[$i]{"state"}{"lastmod"} || time,
        "sourceurl" => $self->{"crl"}[$i]{"state"}{"sourceurl"} || "null:"
      );
    } else {
      foreach my $url ( split(//,$self->{"crlurls"}[$i]) ) {
        # of these, the first one wins
        $url =~ /^(http:|https:|ftp:)/ and 
          ($result,%response) = $self->retrieveHTTP($i,$url);
        $url =~ /^(file:)/ and 
          ($result,%response) = $self->retrieveFile($i,$url);
        last if $result;
      }
    }

    # check if result is there, otherwise invoke agingtolerance clause
    # before actually raising this as an error
    # note that agingtolerance stats counting only AFTER the freshness
    # of the cache control directives has passed ...

    if ( ! $result ) {

      $::log->verb(1,"CRL retrieval for",
                     $self->{"alias"},($i?"[$i] ":"")."failed from all URLs");

      if ( $self->{"agingtolerance"} && $self->{"crl"}[$i]{"state"}{"mtime"} ) {
         if ( ( time - $self->{"crl"}[$i]{"state"}{"mtime"} ) < 
              3600*$self->{"agingtolerance"}) {
           $::log->warn("CRL retrieval for",
                     $self->{"alias"},($i?"[$i] ":"")."failed,", 
                     int((3600*$self->{"agingtolerance"}+
                         $self->{"crl"}[$i]{"state"}{"mtime"}-
                         time )/3600).
                     " left of ".$self->{"agingtolerance"}."h, retry later.");
         } else {
        $::log->err("CRL retrieval for",
                     $self->{"alias"},($i?"[$i] ":"")."failed.",
                     $self->{"agingtolerance"}."h grace expired.",
                     "CRL not updated");
         }
      } else { # direct errors, no tolerance anymore
        $::log->err("CRL retrieval for",
                     $self->{"alias"},($i?"[$i] ":"")."failed,",
                     "CRL not updated");
      }
      next; # next subindex CRL for same CA, no further action on this one
    }

    # now data for $i is loaded in $result;
    # for freshness checks, take a sum (SysV style)
    my $sum = unpack("%32C*",$result) % 65535;

    $::log->verb(4,"Got",length($result),"bytes of data (sum=$sum)");

    $self->{"crl"}[$i]{"data"} = $result;
    $self->{"crl"}[$i]{"state"}{"alias"} = $self->{"alias"};
    $self->{"crl"}[$i]{"state"}{"index"} = $i;
    $self->{"crl"}[$i]{"state"}{"sum"} = $sum;
    ($self->{"crl"}[$i]{"state"}{"b64data"} = 
       base64::b64encode($result)) =~ s/\s+//gm;

    $self->{"crl"}[$i]{"state"}{"retrievaltime"} = time;
    $self->{"crl"}[$i]{"state"}{"sourceurl"} = $response{"sourceurl"}||"null:";
    $self->{"crl"}[$i]{"state"}{"freshuntil"} = $response{"freshuntil"}||time;
    $self->{"crl"}[$i]{"state"}{"lastmod"} = $response{"lastmod"}||time;

  }
  return 1;
}

sub verifyAndConvertCRLs($) {
  my $self = shift;
  $self->{"crlurls"} or
    $::log->err("Verifying uninitialised list of CRLs impossible") and return 0;

  # all CRLs must be valid in order to proceed
  # or we would end up shifting the relative ordering around and
  # possibly creatiing holes (or overwriting good local copies of
  # CRLs that have gone bad on the remote end

  for ( my $i = 0; $i <= $#{$self->{"crlurls"}} ; $i++ ) { # all indices
    $self->{"crlurls"}[$i] or 
      $::log->verb(3,"CRL",$self->getAnchorName."/".$i,"ignored (no valid URL)")
      and next;
    $self->{"crl"}[$i]{"data"} or 
      $::log->verb(3,"CRL",$self->getAnchorName."/".$i,"ignored (no new data)")
      and next;
    $::log->verb(4,"Verifying CRL $i for",$self->getAnchorName);

    my $crl = CRL->new($self->getAnchorName."/$i",$self->{"crl"}[$i]{"data"});
    my @verifyMessages= $crl->verify(@{$self->{"cafile"}});
 
    # do additional checks on correlation between download and current
    # lastUpdate of current file? have to guess the current file
    # unless we are stateful!
    my $oldlastupdate = $self->{"crl"}[$i]{"state"}{"lastupdate"} || undef;
    $oldlastupdate or do {
      $::log->verb(6,"Attempting to extract lastUpdate of previous D/L");
      CRLSTATEHUNT: foreach my $output ( @{$::cnf->{_}->{"output_"}} ,
                                         $self->{"infodir"}
                                       ) {
        foreach my $file (
              $self->{"nametemplate_der"},
              $self->{"nametemplate_pem"},
              $self->{"alias"}.".r\@R\@",
              $self->{"anchorname"}.".r\@R\@",
            ) {
          next unless $file;
          (my $thisfile = $file ) =~ s/\@R\@/$i/g;
          $thisfile = join "/", $output, $thisfile;
          $::log->verb(6,"Trying guess $file for old CRL");
          next if ! -e $thisfile;
          my $oldcrldata; {
            open OCF,$thisfile and do {
              binmode OCF;
              local $/;
              $oldcrldata = <OCF>;
              close OCF;
            }
          }
          my $oldcrl =  CRL->new($thisfile,$oldcrldata);
          $oldlastupdate = $oldcrl->getLastUpdate;
          last CRLSTATEHUNT;
        }
      }
      $::log->verb(3,"Inferred lastupdate for",$self->{"alias"},"is",
                     $oldlastupdate) if $oldlastupdate;
    };

    if ( ! $crl->getLastUpdate ) {
      push @verifyMessages,"downloaded CRL lastUpdate could not be derived";
    } elsif ( $oldlastupdate and ($crl->getLastUpdate < $oldlastupdate) and
         ($self->{"crl"}[$i]{"state"}{"mtime"} <= time)
       ) {
      push @verifyMessages,"downloaded CRL lastUpdate predates installed CRL,",
                           "and current version has sane timestamp";
    } elsif ( defined $oldlastupdate and $oldlastupdate > time ) {
      $::log->warn($self->{"anchorname"}."/$i:","replaced with downloaded CRL",
                   "since current one has lastUpdate in the future");
    }

    $#verifyMessages >= 0 and do {
      $::log->err("CRL verification failed for",$self->{"anchorname"}."/$i",
                  "(".$self->{"alias"}.")");
      foreach my $m ( @verifyMessages ) {
        $::log->verb(0,$self->{"anchorname"}."/$i:",$m);
      }
      return 0;
    };

    $self->{"crl"}[$i]{"pemdata"} = $crl->getPEMdata();
    foreach my $key ( qw/ lastupdate nextupdate sha1fp issuer / ) {
      $self->{"crl"}[$i]{"state"}{$key} = $crl->getAttribute($key) || "";
    }
  }
  return 1;
}


1;

