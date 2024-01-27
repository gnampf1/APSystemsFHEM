###############################################################################
# $Id: 00_APsystemsInverter.pm  $
#
# this module is part of fhem under the same license
# copyright 2019, Daniel Ridders
#
###############################################################################
package main;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(time);
use DateTime::Format::Strptime;

our $deb = 1;

sub APsystemsInverter_Initialize {
  my ($hash) = @_;

  $hash->{Clients}        = "";

  $hash->{MatchList}      = {};

  $hash->{DefFn}          = "APsystemsInverter_Define";
  $hash->{ParseFn}        = "APsystemsInverter_Parse";

  $hash->{Match}          = '^ECU[0-9]{12}INV[0-9]{12}DATA.*$';

  $hash->{AutoCreate} = {"APsystemsInverter_.*"  => { autocreateThreshold => "1:0" }
                        };

  return undef;
};

sub APsystemsInverter_Define {
    my ($hash, $def) = @_;

    my ($ecuId, $invId) = $def =~ m/([0-9]{12}) ([0-9]{12})/;
    if (not defined $ecuId or $ecuId eq "")
    {
        return "No ECUID specified";
    }
    if (not defined $invId or $invId eq "")
    {
        return "No InverterId specified";
    }

    my $id = "$ecuId:$invId";
    $modules{APsystemsInverter}{defptr}{$id} = $hash;
#    $modules{APsystemsInverter}->{Match} = "ECU".$ecuId."INV".$invId."DATA.*";

    $hash->{ID} = $id;

    AssignIoPort($hash, "APSystemsEMA");
  
    return undef;
};

sub APsystemsInverter_Parse
{
    my ($iohash, $msg) = @_;
    my $name = $iohash->{'NAME'};
    my ($ecuId, $invId, $json) = $msg =~ /ECU([0-9]{12})INV([0-9]{12})DATA(.*)$/;

    Log3(undef, 3, "APsystemsInverter_Parse called for ECU $ecuId, Inverter $invId");

    my $hash = $modules{APsystemsInverter}{defptr}{"$ecuId:$invId"};
    if(defined $hash) 
    {
        $name = $hash->{NAME};
        Log3($hash->{NAME}, 3, "APSystemsInverter found $hash->{NAME}");
        $json = decode_json($json);
        
        my @freq = @{ $json->{HZ} };
        my @activePower = @{ $json->{AP} };
        my @reactivePower = @{ $json->{RP} };
        my @overallPower = @{ $json->{OP} };
        my @acVoltage = @{ $json->{AV} };
        my @temperature = @{ $json->{TM} };
        my @time = @{ $json->{time} };

        my $data;
        for (my $i = 0; $i < scalar @time; $i++)
        {
            my $tm = $time[$i];
            $data->{$tm}{Freq} = $freq[$i];
            $data->{$tm}{ActivePower} = $activePower[$i];
            $data->{$tm}{ReactivePower} = $reactivePower[$i];
            $data->{$tm}{OverallPower} = $overallPower[$i];
            $data->{$tm}{ACVoltage} = $acVoltage[$i];
            $data->{$tm}{Temperature} = $temperature[$i];
            my $x = 1;
            while (defined $json->{"P$x"})
            {
                my @power = @{ $json->{"P$x"} };
                my @current = @{ $json->{"DA$x"} };
                my @voltage = @{ $json->{"DV$x"} };
                $data->{$tm}{"Inverter$x"}{Power} = $power[$i];
                $data->{$tm}{"Inverter$x"}{Voltage} = $voltage[$i];
                $data->{$tm}{"Inverter$x"}{Current} = $current[$i];
                $x++;
            }
        }

        $hash->{CHANGED} = ();
        $hash->{CHANGETIME} = ();

        my $currPower;
        foreach my $key ( sort {$a <=> $b} keys %{ $data })
        {
            my $dt = DateTime->from_epoch(epoch => $key / 1000);
            my $tz = DateTime::TimeZone->new(name => "America/Denver"); # Data seems to have an 6 hour offset, not sure if with DST or not
            $dt->add(seconds => -$tz->offset_for_datetime($dt));
            $dt->set_time_zone("local");

            my $parser = DateTime::Format::Strptime->new(
                pattern => '%Y-%m-%d %H:%M:%S',
                on_error => 'croak',
            );
            my $readingsDt = $parser->parse_datetime(ReadingsTimestamp($name, "ActivePower", "1900-01-01 00:00:00"));
            $readingsDt->set_time_zone("local");

            if ($readingsDt->epoch < $dt->epoch)
            {
                my $item = $data->{$key};

                my $ts = $dt->strftime("%Y-%m-%d %H:%M:%S");

                $currPower = 0;
                APsystemsInverter_SetVal($hash, "ActivePower", $item->{ActivePower}, $ts);
                APsystemsInverter_SetVal($hash, "OverallPower", $item->{OverallPower}, $ts);
                APsystemsInverter_SetVal($hash, "ReactivePower", $item->{ReactivePower}, $ts);
                APsystemsInverter_SetVal($hash, "Temperature", $item->{Temperature}, $ts);
                APsystemsInverter_SetVal($hash, "Frequency", $item->{Freq}, $ts);
                APsystemsInverter_SetVal($hash, "ACVoltage", $item->{ACVoltage}, $ts);

                my $x = 1;
                while (defined $item->{"Inverter$x"})
                {
                    APsystemsInverter_SetVal($hash, "DCPower$x", $item->{"Inverter$x"}{Power}, $ts);
                    APsystemsInverter_SetVal($hash, "DCVoltage$x", $item->{"Inverter$x"}{Voltage}, $ts);
                    APsystemsInverter_SetVal($hash, "DCCurrent$x", $item->{"Inverter$x"}{Current}, $ts);
                    $currPower += $item->{"Inverter$x"}{Power};
                    $x++;
                }
                APsystemsInverter_SetVal($hash, "TotalPowerDC", $currPower, $ts);
            }
            else
            {
                my $x = 1;
                while (defined $item->{"Inverter$x"})
                {
                    $currPower += $item->{"Inverter$x"}{Power};
                    $x++;
                }
            }
        }

        readingsSingleUpdate($hash,"state", "Heute: $json->{total} kWh, Gesamt: ???, Aktuell: $currPower W",1);

        return $hash->{NAME};
    }
    else
    {
      Log3 (undef, 3, "APsystemsInverter: couldn't find $ecuId:$invId");
      return "UNDEFINED APsystemsInverter_$invId APsystemsInverter $ecuId $invId";
    }
};

sub APsystemsInverter_SetVal
{
    my ($hash, $reading, $value, $ts) = @_;

    setReadingsVal($hash, $reading, $value, $ts);
    push(@{$hash->{CHANGED}}, "$reading: $value");   # this is the function of addEvevnt
    push(@{$hash->{CHANGETIME}}, $ts);   # set old timestamp

    return undef;
};

1;
