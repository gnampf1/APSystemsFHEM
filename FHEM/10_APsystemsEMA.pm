###############################################################################
# $Id: 10_APsystemsEMA.pm  $
#
# this module is part of fhem under the same license
# copyright 2023, Daniel Ridders
#
###############################################################################
package main;

use strict;
use warnings;
use utf8;
use Try::Tiny::SmartCatch;
use HttpUtils;
use POSIX qw(strftime);
use JSON;

our $deb = 1;

sub APsystemsEMA_Initialize {
  my ($hash) = @_;

  $hash->{Clients}        = "APsystemsInverter";

  $hash->{MatchList}      = { "1:APsystemsInverter"                     => '^ECU[0-9]{12}INV[0-9]{12}DATA.*$'
                            };

  $hash->{DefFn}          = "APsystemsEMA_Define";
  $hash->{UndefFn}        = "APsystemsEMA_Shutdown";
  $hash->{NotifyFn}       = "APsystemsEMA_Notify";
  $hash->{DeleteFn}       = "APsystemsEMA_Delete";
  $hash->{ShutdownFn}     = "APsystemsEMA_Shutdown";
#  $hash->{AttrList}   	  = "".$readingFnAttributes;
  
  return undef;
};

sub APsystemsEMA_Define {
  my ($hash, $def) = @_;
  my ($name, $module, $user, $pw) = split / /, $def;

  notifyRegexpChanged($hash, 'global');

  $hash->{Username} = $user;
  $hash->{Password} = $pw;

  APsystemsEMA_Run($hash) if ($init_done);

  return undef;
};

sub APsystemsEMA_Notify {
  my ($hash, $ntfyDev) = @_;
  my $events = deviceEvents($ntfyDev,1);
  return undef if(!$events);
  foreach my $event (@{$events}) {
    next if (!defined($event));
    APsystemsEMA_Run($hash) if ($event eq 'INITIALIZED');
  };
  return undef;
};

sub APsystemsEMA_Run {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3($name, 5, "APsystemsEMA_Run called");
  APsystemsEMA_Timer($hash);

  return undef;
};

sub APsystemsEMA_Timer {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3($name, 5, "APsystemsEMA_Timer called");

  $hash->{Cookie} = undef;
  $hash->{HTTPCookieHash} = undef;

  try sub {
    my $param = {
                    url        => "https://www.apsystemsema.com/",
                    timeout    => 5,
                    hash       => $hash,
                    method     => "GET",
                    callback   => \&APsystemsEMA_SessionIdResponse,
                    ignoreredirects => 0
                };

    HttpUtils_NonblockingGet($param);                                                                                    # Starten der HTTP Abfrage. Es gibt keinen Return-Code. 
  }, finally sub {
    InternalTimer(gettimeofday() + 60, "APsystemsEMA_Timer", $hash);
  };

  return undef;
};

sub APsystemsEMA_GetYYYYMMDD
{
    return strftime "%Y%m%d", localtime;
};

sub APsystemsEMA_SessionIdResponse
{
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    Log3($name, 5, "APsystemsEMA_SessionIdResponse called");

    if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
        readingsSingleUpdate($hash, "fullResponse", "ERROR", 0);                                                        # Readings erzeugen
    }

    else
    {

        my $date = urlEncode(strftime("%Y-%m-%d+%H:%M:%S",localtime));
        my $username = urlEncode($hash->{Username});
        my $password = urlEncode($hash->{Password});
	$hash->{Cookie} = APsystemsEMA_GetCookies($hash,$param->{httpheader});
        my $param = {
                        url        => "https://www.apsystemsema.com/ema/loginEMA.action",
                        timeout    => 5,
                        hash       => $hash,
                        method     => "POST",
                        header     => { "Content-Type" => "application/x-www-form-urlencoded;",
                                        "Cookie" => $hash->{Cookie}
                                      },
                        callback   => \&APsystemsEMA_LoginResponse,
                        data       => "today=$date&code=&username=$username&password=$password&verifyCode=+",	
                        ignoreredirects => 1
                    };

        HttpUtils_NonblockingGet($param);                                                                                    # Starten der HTTP Abfrage. Es gibt keinen Return-Code. 
    }

    return undef;
};

sub APsystemsEMA_LoginResponse
{
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    Log3($name, 5, "APsystemsEMA_LoginResponse called");

    if($err ne "")
    {
        Log3 $name, 3, "error while requesting ".$param->{url}." - $err";
    }
    else
    {
	$hash->{Cookie} = APsystemsEMA_GetCookies($hash,$param->{httpheader});
        $hash->{UserId} = $hash->{HTTPCookieHash}{userId}{Value};

	if (not defined $hash->{InverterList} or scalar(@{$hash->{InverterList}}) == 0)
        {
            Log3($name, 3, "Inverterlist is not defined, retrieving list");

            my $param = {
                        url        => "https://www.apsystemsema.com/ema/security/optmainmenu/intoViewSingleCustomerBelowInstaller.action?userId=" . $hash->{UserId},
                        timeout    => 5,
                        hash       => $hash,
                        method     => "GET",
                        header     => { 
                                        "Cookie" => $hash->{Cookie}
                                      },
                    };
            (my $err1, my $data1) = HttpUtils_BlockingGet($param);


            $param = {
                        url        => "https://www.apsystemsema.com/ema/security/optsecondmenu/intoUIDLevel.action",
                        timeout    => 5,
                        hash       => $hash,
                        method     => "GET",
                        header     => { 
                                        "Cookie" => $hash->{Cookie}
                                      },
                    };
            (my $err, my $data) = HttpUtils_BlockingGet($param);

            my @arr = ( $data =~ /(<[^>]*>)/g );
            my @filteredArr = grep { $_ =~ m/<option[^>]*value="[0-9]{12}"[^>]*>/ } @arr;
            my $ecuList;
            my @inverterList;
            foreach my $option (@filteredArr) {
                if ($option =~ m/title="$hash->{UserId}"/) {
                    (my $ecuId = $option) =~ s/.*value="([0-9]{12}).*/$1/;
                    (my $cfg = $option) =~ s/.*cfg="([0-9]+)".*/$1/;
                    $ecuList->{$cfg} = $ecuId;
                    Log3($name, 5, "Got ECU $ecuId, cfg $cfg");
                } elsif ($option =~ m/cfg="[0-9]+\//) {
                    (my $invId = $option) =~ s/.*value="([0-9]{12}).*/$1/;
                    (my $type = $option) =~ s/.*title="([0-9]+)".*/$1/;
                    (my $cfgInv = $option) =~ s/.*cfg="([0-9]+)\/[0-9]+.*/$1/;
                    
                    Log3($name, 5, "Got Inverter $invId, Type $type, Cfg $cfgInv");
                    push @inverterList, "$ecuList->{$cfgInv}:$invId:$type";
                }
            }
            my @unique = do { my %seen; grep { !$seen{$_}++ } @inverterList };
            $hash->{InverterList} = \@unique;
        }

        $hash->{InvertersToQuery} = $hash->{InverterList};
        APsystemsEMA_QueryInverter($hash);
    }

    return undef;
}

sub APsystemsEMA_QueryInverter
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @inverterLeft = @{ $hash->{InvertersToQuery} };
    my $inverterItem = pop(@inverterLeft);
    $hash->{InvertersToQuery} = \@inverterLeft;

    if (defined $inverterItem)
    {
        Log3($name, 5, "Querying inverter $inverterItem");
        if ($inverterItem ne "") 
        {
            ($hash->{CurrentECU}, $hash->{CurrentINV}, $hash->{CurrentType}) = split /:/m, $inverterItem;
            my $CHANNEL = "0";
            my $YYYYMMDD = APsystemsEMA_GetYYYYMMDD();
            my $param = {
                        url        => "https://www.apsystemsema.com/ema/ajax/getReportAjax/findOPTdayPerformanceAjax",
                        timeout    => 5,
                        hash       => $hash,
                        method     => "POST",
                        header     => { "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
                                        "Accept" => "application/json",
                                        "Cookie" => $hash->{Cookie}
                                      },
                        data => "systemId=$hash->{UserId}&dcId=$hash->{CurrentINV}&channel=0&date=$YYYYMMDD&type=$hash->{CurrentType}&key=$hash->{CurrentECU}$hash->{CurrentINV}$CHANNEL$YYYYMMDD%2Fp",
                        callback   => \&APsystemsEMA_DataResponse,
                    };
            Log3($name, 3, "Request-Data: $param->{data}");
            HttpUtils_NonblockingGet($param);
        }
    } else {
        APsystemsEMA_Logout($hash);
    }

    return undef;
};

sub APsystemsEMA_Logout
{
    my ($hash) = @_;
    my $name = $hash->{NAME};

    Log3($name, 5, "Logging out from EMA portal");
    my $param = {
                url        => "https://www.apsystemsema.com/ema/logoutEMA.action",
                timeout    => 5,
                hash       => $hash,
                method     => "GET",
                header     => { 
                                "Cookie" => $hash->{Cookie}
                              },
            };
    HttpUtils_NonblockingGet($param);

    $hash->{Cookie} = undef;
    $hash->{HTTPCookieHash} = undef;

    return undef;
}

sub APsystemsEMA_DataResponse
{
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if($err ne "")
    {
        Log3 $name, 3, "error while requesting ".$param->{url}." - $err";
    }

    elsif($data ne "")
    {
        Dispatch($hash, "ECU$hash->{CurrentECU}INV$hash->{CurrentINV}DATA$data");
    }
    else
    {
        Log3($name, 3, "No error and no data???");
    }

    APsystemsEMA_QueryInverter($hash);

    return undef;
};

sub APsystemsEMA_GetCookies($$)
{
    my ($hash, $header) = @_;
    my $name = $hash->{NAME};
    Log3 $name, 5, "$name: tahoma_GetCookies looking for Cookies in header";
    Log3 $name, 5, "$name: tahoma_GetCookies header=$header";
    foreach my $cookie ($header =~ m/set-cookie: ?(.*)/gi) {
        Log3 $name, 5, "$name: Set-Cookie: $cookie";
        $cookie =~ /([^,; ]+)=([^,; ]+)[;, ]*(.*)/;
        Log3 $name, 5, "$name: Cookie: $1 Wert $2 Rest $3";
        $hash->{HTTPCookieHash}{$1}{Value} = $2;
        $hash->{HTTPCookieHash}{$1}{Options} = ($3 ? $3 : "");
    }
    return join ("; ", map ($_ . "=".$hash->{HTTPCookieHash}{$_}{Value},
                        sort keys %{$hash->{HTTPCookieHash}}));    
};

sub APsystemsEMA_Delete(@) {
  my ($hash) = @_;
  return undef;
};

sub APsystemsEMA_Shutdown {
  my ($hash) = @_;
  my ($shash, $socket);
  
  RemoveInternalTimer($hash);

  return undef;
};


# take care and leave multicast group in case of unexpexted close. wont work on signals
END {
  APsystemsEMA_Shutdown({});
};

1;
