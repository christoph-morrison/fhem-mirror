########################################################################################
#
# OWX.pm
#
# FHEM module to commmunicate directly with 1-Wire bus devices
# via an active DS2480/DS2490/DS9097U bus master interface or 
# via a passive DS9097 interface
#
# Version 1.07 - March, 2012
#
# Prof. Dr. Peter A. Henning, 2012
#
# Setup interface as:
#
# define <name> OWX <device>
#    
# where <name> may be replaced by any name string 
#       <device> is a serial (USB) device
#
# get <name> alarms   => find alarmed 1-Wire devices
# get <name> devices  => find all 1-Wire devices 
#
# set <name> interval => set period for temperature conversion and alarm testing
#
# attr <name> buspower real/parasitic - whether the 1-Wire bus is really powered or 
#      the 1-Wire devices take their power from the data wire (parasitic is default !)
#
# Ordering of subroutines in this module
# 1. Subroutines independent of bus interface type
# 2. Subroutines for a specific type of the interface
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################
package main;

use strict;
use warnings;
use Device::SerialPort;

# Prototypes to make komodo happy
use vars qw{%attr %defs};
sub Log($$);

# Line counter 
my $cline=0;

# These we may get on request
my %gets = (
   "alarms" => "A",
   "devices" => "D"
);

# These occur in a pulldown menu as settable values for the bus master
my %sets = (
   "interval" => "T"
);

# These are attributes
my %attrs = (
);

#-- some globals needed for the 1-Wire module
my $owx_serport;
#-- baud rate serial interface
my $owx_baud=9600;
#-- Debugging
my $owx_debug=0;
#-- bus master mode
my $owx_mode="undef";
#-- bus interface
my $owx_interface="";
#-- 8 byte 1-Wire device address
my @owx_ROM_ID  =(0,0,0,0 ,0,0,0,0); 
#-- List of addresses found on the bus
my @owx_devs=();
my @owx_fams=();
my @owx_alarm_devs=();
#-- 16 byte search string
my @owx_search=(0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0);
#-- search state for 1-Wire bus search
my $owx_LastDiscrepancy = 0;
my $owx_LastFamilyDiscrepancy = 0;
my $owx_LastDeviceFlag = 0;


########################################################################################
#
# The following subroutines are independent of the bus interface
#
########################################################################################
#
# OWX_Initialize
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWX_Initialize ($) {
  my ($hash) = @_;
  #-- Provider
  #$hash->{Clients}    = ":OWCOUNT:OWHUB:OWLCD:OWMULTI:OWSWITCH:OWTEMP:";
  $hash->{Clients}     = ":OWAD:OWID:OWTEMP:";

  #-- Normal Devices
  $hash->{DefFn}   = "OWX_Define";
  $hash->{UndefFn} = "OWX_Undef";
  $hash->{GetFn}   = "OWX_Get";
  $hash->{SetFn}   = "OWX_Set";
  $hash->{AttrList}= "loglevel:0,1,2,3,4,5,6 buspower:real,parasitic";
}

########################################################################################
#
# OWX_Alarms - Find devices on the 1-Wire bus, 
#              which have the alarm flag set
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : no device present
#
########################################################################################

sub OWX_Alarms ($) {
  my ($hash) = @_;
  my @owx_alarm_names=();
  
  #-- Discover all alarmed devices on the 1-Wire bus
  @owx_alarm_devs=();
  my $res = OWX_First($hash,"alarm");
  while( $owx_LastDeviceFlag==0 && $res != 0){
    $res = $res & OWX_Next($hash,"alarm");
  }
  if( @owx_alarm_devs == 0){
     return "OWX: No alarmed 1-Wire devices found ";
  }

  #-- walk through all the devices to get their proper fhem names
  foreach my $fhem_dev (sort keys %main::defs) {
    #-- skip if busmaster
    next if( $hash->{NAME} eq $main::defs{$fhem_dev}{NAME} );
    #-- all OW types start with OW
    next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
    foreach my $owx_dev  (@owx_alarm_devs) {
      #-- two pieces of the ROM ID found on the bus
      my $owx_rnf = substr($owx_dev,3,12);
      my $owx_f   = substr($owx_dev,0,2);
      my $id_owx  = $owx_f.".".$owx_rnf;
        
      #-- skip if not in alarm list
      if( $owx_dev eq $main::defs{$fhem_dev}{ROM_ID} ){
        $main::defs{$fhem_dev}{STATE} = "Alarmed";
        push(@owx_alarm_names,$main::defs{$fhem_dev}{NAME});
      }
    }
  }
  #-- so far, so good - what do we want to do with this ?
  return "OWX: Alarmed 1-Wire devices found (".join(",",@owx_alarm_names).")";
}  

########################################################################################
# 
# OWX_Block - Send data block 
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub OWX_Block ($$) {
  my ($hash,$data) =@_;
  
  if( $owx_interface eq "DS2480" ){
    return OWX_Block_2480($hash,$data);
  }elsif( $owx_interface eq "DS9097" ){
    return OWX_Block_9097($hash,$data);
  }else{
    Log 1,"OWX: Block called with unknown interface";
    return 0;
  }
}

########################################################################################
#
# OWX_CRC - Check the CRC8 code of a device address in @owx_ROM_ID
#
# Parameter romid = if not zero, return the CRC8 value instead of checking it
#
########################################################################################

sub OWX_CRC ($) {
  my ($romid) = @_;
  
  my @crc8_table = (
    0, 94,188,226, 97, 63,221,131,194,156,126, 32,163,253, 31, 65,
    157,195, 33,127,252,162, 64, 30, 95, 1,227,189, 62, 96,130,220,
    35,125,159,193, 66, 28,254,160,225,191, 93, 3,128,222, 60, 98,
    190,224, 2, 92,223,129, 99, 61,124, 34,192,158, 29, 67,161,255,
    70, 24,250,164, 39,121,155,197,132,218, 56,102,229,187, 89, 7,
    219,133,103, 57,186,228, 6, 88, 25, 71,165,251,120, 38,196,154,
    101, 59,217,135, 4, 90,184,230,167,249, 27, 69,198,152,122, 36,
    248,166, 68, 26,153,199, 37,123, 58,100,134,216, 91, 5,231,185,
    140,210, 48,110,237,179, 81, 15, 78, 16,242,172, 47,113,147,205,
    17, 79,173,243,112, 46,204,146,211,141,111, 49,178,236, 14, 80,
    175,241, 19, 77,206,144,114, 44,109, 51,209,143, 12, 82,176,238,
    50,108,142,208, 83, 13,239,177,240,174, 76, 18,145,207, 45,115,
    202,148,118, 40,171,245, 23, 73, 8, 86,180,234,105, 55,213,139,
    87, 9,235,181, 54,104,138,212,149,203, 41,119,244,170, 72, 22,
    233,183, 85, 11,136,214, 52,106, 43,117,151,201, 74, 20,246,168,
    116, 42,200,150, 21, 75,169,247,182,232, 10, 84,215,137,107, 53);

  my $crc8=0;  

  if( $romid eq "0" ){  
    for(my $i=0; $i<8; $i++){
      $crc8 = $crc8_table[ $crc8 ^ $owx_ROM_ID[$i] ];
    }  
    return $crc8;
  } else {
    #-- from search string to byte id
    $romid=~s/\.//g;
    for(my $i=0;$i<8;$i++){
      $owx_ROM_ID[$i]=hex(substr($romid,2*$i,2));
    }
    for(my $i=0; $i<7; $i++){
      $crc8 = $crc8_table[ $crc8 ^ $owx_ROM_ID[$i] ];
    }  
    return $crc8;
  }
}  

########################################################################################
#
# OWX_CRC16 - Calculate the CRC16 code of a string
#
# Parameter crc - previous CRC code, c next character
#
########################################################################################

sub OWX_CRC16($) {
  my ($data) = @_;

  my $crc=0;
  for( my $i=0; $i<length($data); $i++) {
    $crc = OWX_DOCRC16($crc,substr($data,$i,1));
    printf "=====> New CRC value = %x",$crc;
  }
  return $crc;
}
  
  
sub OWX_DOCRC16($$) {
  my ($crc,$c) = @_;

  #-- polynomial for x^16 + x^15 + x^2 + 1
  my $mask = 0xA001;
  
  my $i;
  for($i=0;$i<8;$i++) {
    if(($crc ^ ord($c)) & 1) { 
      $crc=($crc>>1)^$mask; 
    } else {
      $crc>>=1;
    }
    $c>>=1;
  }
  return ($crc);
}

#//-------------------------------------------------------------------#

#Aufruf der Funktion im Programm:

#{
#//...
#  unsigned int DEVICE_CRC16=0;
#  DEVICE_CRC16 = calcCRC16r (DEVICE_CRC16,chr,0xA001);
#//...
#}



########################################################################################
#
# OWX_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
########################################################################################

sub OWX_Define ($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  
  if(@a == 3){
    #-- If this line contains 3 parameters, it is the bus master definition
    my $dev = $a[2];
    $hash->{DeviceName} = $dev;
    #-- Dummy 1-Wire ROM identifier
    $hash->{ROM_ID} = "FF";

    #-- First step: open the serial device to test it
    #Log 3, "OWX opening device $dev";
    $owx_serport = new Device::SerialPort ($dev);
    return "OWX: Can't open $dev: $!" if(!$owx_serport);
    Log 3, "OWX: opened device $dev";
    $owx_serport->reset_error();
    $owx_serport->baudrate(9600);
    $owx_serport->databits(8);
    $owx_serport->parity('none');
    $owx_serport->stopbits(1);
    $owx_serport->handshake('none');
    $owx_serport->write_settings;
    #-- sleeping for some time
    select(undef,undef,undef,0.1); 
    #$owx_serport->close();
 
    #-- Second step: see, if a bus interface is detected
    if (!OWX_Detect($hash)){
      $hash->{STATE} = "Failed";
      $hash->{PRESENT} = 0;
      $init_done = 1; 
      return undef;
    }
  
    #-- In 10 seconds discover all devices on the 1-Wire bus
    InternalTimer(gettimeofday()+5, "OWX_Discover", $hash,0);
    
    #-- Default settings
    $hash->{interval} = 60;          # kick every minute
    
    #-- InternalTimer blocks if init_done is not true
    my $oid = $init_done;
    $hash->{PRESENT} = 1;
    #$hash->{TYPE}       = "OWX";
    #$hash->{T}       = "OWX";
    $hash->{STATE}      = "Initialized";
    $hash->{INTERFACE}  = $owx_interface;
    $init_done = 1;

    #-- Intiate first alarm detection and eventually conversion in a minute or so
    InternalTimer(gettimeofday() + 60, "OWX_Kick", $hash,1);
    $init_done = $oid;
    $hash->{STATE} = "Active";
    return undef;
  }  
}

########################################################################################
# 
# OWX_Detect - Detect 1-Wire interface
#
# Method rather crude - treated as an 2480, and see whatis returned
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Detect ($) {
  my ($hash) = @_;
  
  my ($i,$j,$k,$l,$res,$ret,$ress);
  #-- timing byte for DS2480
  OWX_Query_2480($hash,"\xC1\xC1");
  
  #-- Max 4 tries to detect an interface
  for($l=0;$l<4;$l++) {
    #-- write 1-Wire bus (Fig. 2 of Maxim AN192)
    $res = OWX_Query_2480($hash,"\x17\x45\x5B\x0F\x91");
    #$ress = "OWX: Answer was ";
    #for($i=0;$i<length($res);$i++){
    #  $j=int(ord(substr($res,$i,1))/16);
    #  $k=ord(substr($res,$i,1))%16;
    #  $ress.=sprintf "0x%1x%1x ",$j,$k;
    #}
    #Log 1, $ress;
    
    #-- process 4/5-byte string for detection
    if( $res eq "\x16\x44\x5A\x00\x93"){
      Log 1, "OWX: 1-Wire bus master DS2480 detected for the first time";
      $owx_interface="DS2480";
      $ret=1;
    } elsif( $res eq "\x17\x45\x5B\x0F\x91"){
      Log 1, "OWX: 1-Wire bus master DS2480 re-detected";
      $owx_interface="DS2480";
      $ret=1;
    } elsif( ($res eq "\x17\x0A\x5B\x0F\x02") || ($res eq "\x00\x17\x0A\x5B\x0F\x02") ){
      Log 1, "OWX: Passive 1-Wire bus interface DS9097 detected";
      $owx_interface="DS9097";
      $ret=1;
    } else {
      $ret=0;
    }
    last 
      if( $ret==1 );
    $ress = "OWX: Trying again to detect an interface, answer was ";
    for($i=0;$i<length($res);$i++){
      $j=int(ord(substr($res,$i,1))/16);
      $k=ord(substr($res,$i,1))%16;
      $ress.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 1, $ress;
    #-- sleeping for some time
    select(undef,undef,undef,0.5);
  }
  if( $ret == 0 ){
    $ress = "OWX: No 1-Wire bus interface detected, answer was ";
    for($i=0;$i<length($res);$i++){
      $j=int(ord(substr($res,$i,1))/16);
      $k=ord(substr($res,$i,1))%16;
      $ress.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 1, $ress;
  }
  return $ret;
}

########################################################################################
#
# OWX_Discover - Discover devices on the 1-Wire bus, 
#                autocreate devices if not already present
#
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : no device present
#
########################################################################################

sub OWX_Discover ($) {
  my ($hash) = @_;
  
  #-- Discover all devices on the 1-Wire bus
  @owx_devs=();
  my @owx_names=();
  my $res = OWX_First($hash,"discover");
  while( $owx_LastDeviceFlag==0 && $res!=0 ){
    $res = $res & OWX_Next($hash,"discover"); 
  }
   
  #-- Check, which of these is already defined in the cfg file
    foreach my $owx_dev  (@owx_devs) {
      #-- two pieces of the ROM ID found on the bus
      my $owx_rnf = substr($owx_dev,3,12);
      my $owx_f   = substr($owx_dev,0,2);
      my $owx_crc = substr($owx_dev,15,3);
      my $id_owx  = $owx_f.".".$owx_rnf;
      
      my $match = 0;
    
      #-- check against all existing devices  
      foreach my $fhem_dev (sort keys %main::defs) { 
        #-- skip if busmaster
        # next if( $hash->{NAME} eq $main::defs{$fhem_dev}{NAME} );
        #-- all OW types start with OW
        next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
        my $id_fhem = substr($main::defs{$fhem_dev}{ROM_ID},0,15);
        #-- testing if present in defined devices   
        if( $id_fhem eq $id_owx ){
          push(@owx_names,$main::defs{$fhem_dev}{NAME});
          #-- replace the ROM ID by the proper value 
          $main::defs{$fhem_dev}{ROM_ID}=$owx_dev;
          $main::defs{$fhem_dev}{PRESENT}=1;
          $match = 1;
          last;
        }
      }
    
      #-- autocreate the device
      if( $match==0 ){
        #-- Default name OWX_FF_XXXXXXXXXXXX, default type = OWX_FF
        my $name = sprintf "OWX_%s_%s",$owx_f,$owx_rnf;
        #-- Family 10 = Temperature sensor, assume DS1820 as default
        if( $owx_f eq "10" ){
          CommandDefine(undef,"$name OWTEMP DS1820 $owx_rnf");         
        #-- Family 20 = A/D converter, assume DS2450 as default
        } elsif( $owx_f eq "20" ){
          CommandDefine(undef,"$name OWAD DS2450 $owx_rnf"); 
        #-- Family 22 = Temperature sensor, assume DS1822 as default
        }elsif( $owx_f eq "22" ){
          CommandDefine(undef,"$name OWTEMP DS1822 $owx_rnf");  
        #-- Family 10 28 = Temperature sensor, assume DS18B20 as default
        }elsif( $owx_f eq "28" ){
          CommandDefine(undef,"$name OWTEMP DS18B20 $owx_rnf");       
        #-- All unknown families are ID only
        } else {
          CommandDefine(undef,"$name OWID $owx_f $owx_rnf");   
        }
        #-- yes, it is on the bus and therefore present
        push(@owx_names,$name);
        $main::defs{$name}{PRESENT}=1;
        #-- default room
        CommandAttr (undef,"$name IODev $hash->{NAME}"); 
        CommandAttr (undef,"$name room OWX"); 
        #-- replace the ROM ID by the proper value 
        $main::defs{$name}{ROM_ID}=$owx_dev;
      }
    }

  #-- final step: Undefine all 1-Wire devices which are not on the bus
  #   TODO: IF WE HAVE MULTIPLE IO Devices ???
  foreach my $fhem_dev (sort keys %main::defs) { 
    #-- skip if malformed device
    #next if( !defined($main::defs{$fhem_dev}{NAME}) );
    #-- all OW types start with OW
    next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
    #-- skip if the device is present.
    next if( $main::defs{$fhem_dev}{PRESENT} == 1);
    Log 1, "OWX: Deleting unused 1-Wire device $main::defs{$fhem_dev}{NAME} of type $main::defs{$fhem_dev}{TYPE}";
    CommandDelete(undef,$main::defs{$fhem_dev}{NAME});
  }
  Log 1, "OWX: 1-Wire devices found (".join(",",@owx_names).")";
  return "OWX: 1-Wire devices found (".join(",",@owx_names).")";
}   

########################################################################################
#
# OWX_First - Find the 'first' devices on the 1-Wire bus
#
# Parameter hash = hash of bus master, mode
#
# Return 1 : device found, ROM number pushed to list
#        0 : no device present
#
########################################################################################

sub OWX_First ($$) {
  my ($hash,$mode) = @_;
  
  #-- clear 16 byte of search data
  @owx_search=(0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0);
  #-- reset the search state
  $owx_LastDiscrepancy = 0;
  $owx_LastDeviceFlag = 0;
  $owx_LastFamilyDiscrepancy = 0;
  #-- now do the search
  return OWX_Search($hash,$mode);
}

########################################################################################
#
# OWX_Get - Implements GetFn function 
#
#  Parameter hash = hash of the bus master a = argument array
#
########################################################################################

sub OWX_Get($@) {
  my ($hash, @a) = @_;
  return "OWX: Get needs exactly one parameter" if(@a != 2);

  my $name     = $hash->{NAME};
  my $owx_dev  = $hash->{ROM_ID};

  if( $a[1] eq "alarms") {
    my $res = OWX_Alarms($hash);
    #-- process result
    return $res
    
  } elsif( $a[1] eq "devices") {
    my $res = OWX_Discover($hash);
    #-- process result
    return $res
    
  } else {
    return "OWX: Get with unknown argument $a[1], choose one of ". 
    join(",", sort keys %gets);
  }
}

########################################################################################
#
# OWX_Kick - Initiate some processes in all devices
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : Not OK
#
########################################################################################

sub OWX_Kick($) {
  
  my($hash) = @_;
  
  my $ret;
  #-- Call us in n seconds again.
  InternalTimer(gettimeofday()+ $hash->{interval}, "OWX_Kick", $hash,1);
  
  OWX_Reset($hash);
  
  #-- Only if we have real power on the bus
  if( defined($attr{$hash->{NAME}}{buspower}) &&  ($attr{$hash->{NAME}}{buspower} eq "real") ){
    #-- issue the skip ROM command \xCC followed by start conversion command \x44
    $ret = OWX_Block($hash,"\xCC\x44");
    if( $ret eq 0 ){
      Log 3, "OWX: Failure in temperature conversion\n";
      return 0;
    }
    #-- sleeping for some time
    select(undef,undef,undef,0.5);
  }
  
  return 1;
}

########################################################################################
#
# OWX_Next - Find the 'next' devices on the 1-Wire bus
#
# Parameter hash = hash of bus master, mode
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub OWX_Next ($$) {
  my ($hash,$mode) = @_;
  #-- now do the search
  return OWX_Search($hash,$mode);
}

########################################################################################
# 
# OWX_Reset - Reset the 1-Wire bus 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Reset ($) {

  my ($hash)=@_;
  if( $owx_interface eq "DS2480" ){
    return OWX_Reset_2480($hash);
  }elsif( $owx_interface eq "DS9097" ){
    return OWX_Reset_9097($hash);
  }else{
    Log 1,"OWX: Reset called with unknown interface";
    return 0;
  }
}

########################################################################################
#
# OWX_Search - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub OWX_Search ($$) {
  my ($hash,$mode)=@_;
  
  #-- if the last call was the last one, no search 
  if ($owx_LastDeviceFlag==1){
    return 0;
  }
  #-- 1-Wire reset
  if (OWX_Reset($hash)==0){
    #-- reset the search
    Log 1, "OWX: Search reset failed";
    $owx_LastDiscrepancy = 0;
    $owx_LastDeviceFlag = 0;
    $owx_LastFamilyDiscrepancy = 0;
    return 0;
  }
  
  #-- Here we call the device dependent part
  if( $owx_interface eq "DS2480" ){
    OWX_Search_2480($hash,$mode);
  }elsif( $owx_interface eq "DS9097" ){
    OWX_Search_9097($hash,$mode);
  }else{
    Log 1,"OWX: Search called with unknown interface";
    return 0;
  }
  #--check if we really found a device
  if( OWX_CRC(0)!= 0){  
  #-- reset the search
    Log 1, "OWX: Search CRC failed ";
    $owx_LastDiscrepancy = 0;
    $owx_LastDeviceFlag = 0;
    $owx_LastFamilyDiscrepancy = 0;
    return 0;
  }
    
  #-- character version of device ROM_ID, first byte = family 
  my $dev=sprintf("%02X.%02X%02X%02X%02X%02X%02X.%02X",@owx_ROM_ID);
 
  #-- for some reason this does not work - replaced by another test, see below
  #if( $owx_LastDiscrepancy==0 ){
  #    $owx_LastDeviceFlag=1;
  #}
  #--
  if( $owx_LastDiscrepancy==$owx_LastFamilyDiscrepancy ){
      $owx_LastFamilyDiscrepancy=0;    
  }
    
  #-- mode was to verify presence of a device
  if ($mode eq "verify") {
    Log 5, "OWX: Device verified $dev";
    return 1;
  #-- mode was to discover devices
  } elsif( $mode eq "discover" ){
    #-- check families
    my $famfnd=0;
    foreach (@owx_fams){
      if( substr($dev,0,2) eq $_ ){        
        #-- if present, set the fam found flag
        $famfnd=1;
        last;
      }
    }
    push(@owx_fams,substr($dev,0,2)) if( !$famfnd );
    foreach (@owx_devs){
      if( $dev eq $_ ){        
        #-- if present, set the last device found flag
        $owx_LastDeviceFlag=1;
        last;
      }
    }
    if( $owx_LastDeviceFlag!=1 ){
      #-- push to list
      push(@owx_devs,$dev);
      Log 5, "OWX: New device found $dev";
    }  
    return 1;
    
  #-- mode was to discover alarm devices 
  } else {
    for(my $i=0;$i<@owx_alarm_devs;$i++){
      if( $dev eq $owx_alarm_devs[$i] ){        
        #-- if present, set the last device found flag
        $owx_LastDeviceFlag=1;
        last;
      }
    }
    if( $owx_LastDeviceFlag!=1 ){
    #--push to list
      push(@owx_alarm_devs,$dev);
      Log 5, "OWX: New alarm device found $dev";
    }  
    return 1;
  }
}
  
########################################################################################
#
# OWX_Set - Implements SetFn function
# 
# Parameter hash , a = argument array
#
########################################################################################

sub OWX_Set($@) {
  my ($hash, @a) = @_;
  my $name = shift @a;
  my $res;

  #-- First we need to find the ROM ID corresponding to the device name
  my $owx_romid =  $hash->{ROM_ID};
  Log 5, "OWX_Set request $name $owx_romid ".join(" ",@a);

  #-- for the selector: which values are possible
  return join(" ", sort keys %sets) if(@a != 2);
  return "OWX_Set: With unknown argument $a[0], choose one of " . join(" ", sort keys %sets)
    if(!defined($sets{$a[0]}));
    
  #-- Set timer value
  if( $a[0] eq "interval" ){
    #-- only values >= 15 secs allowed
    if( $a[1] >= 15){
      $hash->{interval} = $a[1];  
  	  $res = 1;
  	} else {
  	  $res = 0;
  	}
    Log GetLogLevel($name,3), "OWX_Set $name ".join(" ",@a)." => $res";  
  	DoTrigger($name, undef) if($init_done);
    return "OWX_Set => $name ".join(" ",@a)." => $res";
  }
}

########################################################################################
#
# OWX_Undef - Implements UndefFn function
#
# Parameter hash = hash of the bus master, name
#
########################################################################################

sub OWX_Undef ($$) {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  return undef;
}

########################################################################################
#
# OWX_Verify - Verify a particular device on the 1-Wire bus
#
# Parameter hash = hash of bus master, dev =  8 Byte ROM ID of device to be tested
#
# Return 1 : device found
#        0 : device not
#
########################################################################################

sub OWX_Verify ($$) {
  my ($hash,$dev) = @_;
  my $i;
  #-- from search string to byte id
  my $devs=$dev;
  $devs=~s/\.//g;
  for($i=0;$i<8;$i++){
     $owx_ROM_ID[$i]=hex(substr($devs,2*$i,2));
  }
  #-- reset the search state
  $owx_LastDiscrepancy = 64;
  $owx_LastDeviceFlag = 0;
  #-- now do the search
  my $res=OWX_Search($hash,"verify");
  my $dev2=sprintf("%02X.%02X%02X%02X%02X%02X%02X.%02X",@owx_ROM_ID);
  #-- reset the search state
  $owx_LastDiscrepancy = 0;
  $owx_LastDeviceFlag = 0;
  #-- check result
  if ($dev eq $dev2){
    return 1;
  }else{
    return 0;
  }
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a DS2480 bus interface
#
#########################################################################################
# 
# OWX_Block_2480 - Send data block (Fig. 6 of Maxim AN192)
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub OWX_Block_2480 ($$) {
  my ($hash,$data) =@_;
  
   my $data2="";
  #-- if necessary, prepend E1 character for data mode
  if( ($owx_mode ne "data") && (substr($data,0,1) ne '\xE1')) {
    $data2 = "\xE1";
  }
  #-- all E3 characters have to be duplicated
  for(my $i=0;$i<length($data);$i++){
    my $newchar = substr($data,$i,1);
    $data2=$data2.$newchar;
    if( $newchar eq '\xE3'){
      $data2=$data2.$newchar;
    }
  }
  #-- write 1-Wire bus as a single string
  my $res =OWX_Query_2480($hash,$data2);
  return $res;
}

########################################################################################
# 
# OWX_Level_2480 - Change power level (Fig. 13 of Maxim AN192)
#
# Parameter hash = hash of bus master, newlevel = "normal" or something else
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Level_2480 ($$) {
  my ($hash,$newlevel) =@_;
  my $cmd="";
  #-- if necessary, prepend E3 character for command mode
  if( $owx_mode ne "command") {
    $cmd = "\xE3";
  }
  #-- return to normal level
  if( $newlevel eq "normal" ){
    $cmd=$cmd."\xF1\xED\xF1";
    #-- write 1-Wire bus
    my $res = OWX_Query_2480($hash,$cmd);
    #-- process result
    my $r1  = ord(substr($res,0,1)) & 236;
    my $r2  = ord(substr($res,1,1)) & 236;
    if( ($r1 eq 236) && ($r2 eq 236) ){
      Log 5, "OWX: Level change to normal OK";
      return 1;
    } else {
      Log 3, "OWX: Failed to change to normal level";
      return 0;
    }
  #-- start pulse  
  } else {    
    $cmd=$cmd."\x3F\xED";
    #-- write 1-Wire bus
    my $res = OWX_Query_2480($hash,$cmd);
    #-- process result
    if( $res eq "\x3E" ){
      Log 5, "OWX: Level change OK";
      return 1;
    } else {
      Log 3, "OWX: Failed to change level";
      return 0;
    }
  }
}

########################################################################################
#
# OWX_Query_2480 - Write to and read from the 1-Wire bus
# 
# Parameter: hash = hash of bus master, cmd = string to send to the 1-Wire bus
#
# Return: string received from the 1-Wire bus
#
########################################################################################

sub OWX_Query_2480 ($$) {

  my ($hash,$cmd) = @_;
  my ($i,$j,$k);
  my $dev = $hash->{DeviceName};

  $owx_serport->baudrate($owx_baud);
  $owx_serport->write_settings;

  if( $owx_debug > 1){
    my $res = "OWX: Sending out ";
    for($i=0;$i<length($cmd);$i++){  
      $j=int(ord(substr($cmd,$i,1))/16);
      $k=ord(substr($cmd,$i,1))%16;
  	$res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 3, $res;
  }
	
  my $count_out = $owx_serport->write($cmd);

  Log 1, "OWX: Write incomplete $count_out ne ".(length($cmd))."" if ( $count_out != length($cmd) );
  #-- sleeping for some time
  select(undef,undef,undef,0.04);
 
  #-- read the data
  my ($count_in, $string_in) = $owx_serport->read(48);
    
  if( $owx_debug > 1){
    my $res = "OWX: Receiving ";
    for($i=0;$i<$count_in;$i++){  
      $j=int(ord(substr($string_in,$i,1))/16);
      $k=ord(substr($string_in,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 3, $res;
  }
	
  #-- sleeping for some time
  select(undef,undef,undef,0.04);
   
  #$owx_serport->close();
  return($string_in);
}

########################################################################################
# 
# OWX_Reset_2480 - Reset the 1-Wire bus (Fig. 4 of Maxim AN192)
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Reset_2480 ($) {

  my ($hash)=@_;
  my $cmd="";
 
  my ($res,$r1,$r2);
  #-- if necessary, prepend \xE3 character for command mode
  if( $owx_mode ne "command" ) {
    $cmd = "\xE3";
  }
  #-- Reset command \xC5
  $cmd  = $cmd."\xC5"; 
  #-- write 1-Wire bus
  $res =OWX_Query_2480($hash,$cmd);

  #-- if not ok, try for max. a second time
  $r1  = ord(substr($res,0,1)) & 192;
  if( $r1 != 192){
    $res =OWX_Query_2480($hash,$cmd);
  }

  #-- process result
  $r1  = ord(substr($res,0,1)) & 192;
  if( $r1 != 192){
    Log 3, "OWX: Reset failure";
    return 0;
  }
  
  $r2 = ord(substr($res,0,1)) & 3;
  
  if( $r2 == 3 ){
    Log 3, "OWX: No presence detected";
    return 0;
  }elsif( $r2 ==2 ){
    Log 1, "OWX: Alarm presence detected";
  }
  return 1;
}

########################################################################################
#
# OWX_Search_2480 - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub OWX_Search_2480 ($$) {
  my ($hash,$mode)=@_;
  
  my ($sp1,$sp2,$response,$search_direction,$id_bit_number);
    
  #-- Response search data parsing operates bytewise
  $id_bit_number = 1;
  
  select(undef,undef,undef,0.5);
  
  #-- clear 16 byte of search data
  @owx_search=(0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0);
  #-- Output search data construction (Fig. 9 of Maxim AN192)
  #   operates on a 16 byte search response = 64 pairs of two bits
  while ( $id_bit_number <= 64) {
    #-- address single bits in a 16 byte search string
    my $newcpos = int(($id_bit_number-1)/4);
    my $newimsk = ($id_bit_number-1)%4;
    #-- address single bits in a 8 byte id string
    my $newcpos2 = int(($id_bit_number-1)/8);
    my $newimsk2 = ($id_bit_number-1)%8;

    if( $id_bit_number <= $owx_LastDiscrepancy){
      #-- first use the ROM ID bit to set the search direction  
      if( $id_bit_number < $owx_LastDiscrepancy ) {
        $search_direction = ($owx_ROM_ID[$newcpos2]>>$newimsk2) & 1;
        #-- at the last discrepancy search into 1 direction anyhow
      } else {
        $search_direction = 1;
      } 
      #-- fill into search data;
      $owx_search[$newcpos]+=$search_direction<<(2*$newimsk+1);
    }
    #--increment number
    $id_bit_number++;
  }
  #-- issue data mode \xE1, the normal search command \xF0 or the alarm search command \xEC 
  #   and the command mode \xE3 / start accelerator \xB5 
  if( $mode ne "alarm" ){
    $sp1 = "\xE1\xF0\xE3\xB5";
  } else {
    $sp1 = "\xE1\xEC\xE3\xB5";
  }
  #-- issue data mode \xE1, device ID, command mode \xE3 / end accelerator \xA5
  $sp2=sprintf("\xE1%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c\xE3\xA5",@owx_search); 
  $response = OWX_Query_2480($hash,$sp1); 
  $response = OWX_Query_2480($hash,$sp2);   
     
  #-- interpret the return data
  if( length($response)!=16 ) {
    Log 3, "OWX: Search 2nd return has wrong parameter with length = ".length($response)."";
    return 0;
  }
  #-- Response search data parsing (Fig. 11 of Maxim AN192)
  #   operates on a 16 byte search response = 64 pairs of two bits
  $id_bit_number = 1;
  #-- clear 8 byte of device id for current search
  @owx_ROM_ID =(0,0,0,0 ,0,0,0,0); 

  while ( $id_bit_number <= 64) {
    #-- adress single bits in a 16 byte string
    my $newcpos = int(($id_bit_number-1)/4);
    my $newimsk = ($id_bit_number-1)%4;

    #-- retrieve the new ROM_ID bit
    my $newchar = substr($response,$newcpos,1);
 
    #-- these are the new bits
    my $newibit = (( ord($newchar) >> (2*$newimsk) ) & 2) / 2;
    my $newdbit = ( ord($newchar) >> (2*$newimsk) ) & 1;

    #-- output for test purpose
    #print "id_bit_number=$id_bit_number => newcpos=$newcpos, newchar=0x".int(ord($newchar)/16).
    #      ".".int(ord($newchar)%16)." r$id_bit_number=$newibit d$id_bit_number=$newdbit\n";
    
    #-- discrepancy=1 and ROM_ID=0
    if( ($newdbit==1) and ($newibit==0) ){
        $owx_LastDiscrepancy=$id_bit_number;
        if( $id_bit_number < 9 ){
        $owx_LastFamilyDiscrepancy=$id_bit_number;
        }
    } 
    #-- fill into device data; one char per 8 bits
    $owx_ROM_ID[int(($id_bit_number-1)/8)]+=$newibit<<(($id_bit_number-1)%8);
  
    #-- increment number
    $id_bit_number++;
  }
  return 1;
}

########################################################################################
# 
# OWX_WriteBytePower_2480 - Send byte to bus with power increase (Fig. 16 of Maxim AN192)
#
# Parameter hash = hash of bus master, dbyte = byte to send
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_WriteBytePower_2480 ($$) {

  my ($hash,$dbyte) =@_;
  my $cmd="\x3F";
  my $ret="\x3E";
  #-- if necessary, prepend \xE3 character for command mode
  if( $owx_mode ne "command") {
    $cmd = "\xE3".$cmd;
  }
  #-- distribute the bits of data byte over several command bytes
  for (my $i=0;$i<8;$i++){
    my $newbit   = (ord($dbyte) >> $i) & 1;
    my $newchar  = 133 | ($newbit << 4);
    my $newchar2 = 132 | ($newbit << 4) | ($newbit << 1) | $newbit;
    #-- last command byte still different
    if( $i == 7){
      $newchar = $newchar | 2;
    }
    $cmd = $cmd.chr($newchar);
    $ret = $ret.chr($newchar2);
  }
  #-- write 1-Wire bus
  my $res = OWX_Query($hash,$cmd);
  #-- process result
  if( $res eq $ret ){
    Log 5, "OWX: WriteBytePower OK";
    return 1;
  } else {
    Log 3, "OWX: WriteBytePower failure";
    return 0;
  }
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a DS9097 bus interface
#
########################################################################################
# 
# OWX_Block_9097 - Send data block (
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub OWX_Block_9097 ($$) {
  my ($hash,$data) =@_;
  
   my $data2="";
   my $res=0;
   for (my $i=0; $i<length($data);$i++){
     $res = OWX_TouchByte_9097($hash,ord(substr($data,$i,1)));
     $data2 = $data2.chr($res);
   }
   return $data2;
}

########################################################################################
#
# OWX_Query_9097 - Write to and read from the 1-Wire bus
# 
# Parameter: hash = hash of bus master, cmd = string to send to the 1-Wire bus
#
# Return: string received from the 1-Wire bus
#
########################################################################################

sub OWX_Query_9097 ($$) {

  my ($hash,$cmd) = @_;
  my ($i,$j,$k);
  my $dev = $hash->{DeviceName};

  $owx_serport->baudrate($owx_baud);
  $owx_serport->write_settings;

  if( $owx_debug > 1){
    my $res = "OWX: Sending out ";
    for($i=0;$i<length($cmd);$i++){  
      $j=int(ord(substr($cmd,$i,1))/16);
      $k=ord(substr($cmd,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 3, $res;
  } 
	
  my $count_out = $owx_serport->write($cmd);

  Log 1, "OWX: Write incomplete $count_out ne ".(length($cmd))."" if ( $count_out != length($cmd) );
  #-- sleeping for some time
  select(undef,undef,undef,0.01);
 
  #-- read the data
  my ($count_in, $string_in) = $owx_serport->read(48);
    
   if( $owx_debug > 1){
    my $res = "OWX: Receiving ";
    for($i=0;$i<$count_in;$i++){  
      $j=int(ord(substr($string_in,$i,1))/16);
      $k=ord(substr($string_in,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 3, $res;
  }
	
  #-- sleeping for some time
  select(undef,undef,undef,0.01);
  
  #$owx_serport->close();
  return($string_in);
}

########################################################################################
# 
# OWX_ReadBit_9097 - Read 1 bit from 1-wire bus  (Fig. 5/6 from Maxim AN214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub OWX_ReadBit_9097 ($) {
  my ($hash) = @_;
  
  #-- set baud rate to 115200 and query!!!
  my $sp1="\xFF";
  $owx_baud=115200;
  my $res=OWX_Query_9097($hash,$sp1);
  $owx_baud=9600;
  #-- process result
  if( substr($res,0,1) eq "\xFF" ){
    return 1;
  } else {
    return 0;
  } 
}

########################################################################################
# 
# OWX_Reset_9097 - Reset the 1-Wire bus (Fig. 4 of Maxim AN192)
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Reset_9097 ($) {

  my ($hash)=@_;
  my $cmd="";
    
  #-- Reset command \xF0
  $cmd="\xF0";
  #-- write 1-Wire bus
  my $res =OWX_Query_9097($hash,$cmd);
  #-- TODO: process result
  #-- may vary between 0x10, 0x90, 0xe0
  return 1;
}

########################################################################################
#
# OWX_Search_9097 - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub OWX_Search_9097 ($$) {

  my ($hash,$mode)=@_;
  
  my ($sp1,$sp2,$response,$search_direction,$id_bit_number);
    
  #-- Response search data parsing operates bitwise
  $id_bit_number = 1;
  my $rom_byte_number = 0;
  my $rom_byte_mask = 1;
  my $last_zero = 0;
      
  #-- issue search command
  $owx_baud=115200;
  $sp2="\x00\x00\x00\x00\xFF\xFF\xFF\xFF";
  $response = OWX_Query_9097($hash,$sp2);
  $owx_baud=9600;
  #-- issue the normal search command \xF0 or the alarm search command \xEC 
  #if( $mode ne "alarm" ){
  #  $sp1 = 0xF0;
  #} else {
  #  $sp1 = 0xEC;
  #}
      
  #$response = OWX_TouchByte($hash,$sp1); 

  #-- clear 8 byte of device id for current search
  @owx_ROM_ID =(0,0,0,0 ,0,0,0,0); 

  while ( $id_bit_number <= 64) {
    #loop until through all ROM bytes 0-7  
    my $id_bit     = OWX_TouchBit_9097($hash,1);
    my $cmp_id_bit = OWX_TouchBit_9097($hash,1);
     
    #print "id_bit = $id_bit, cmp_id_bit = $cmp_id_bit\n";
     
    if( ($id_bit == 1) && ($cmp_id_bit == 1) ){
      #print "no devices present at id_bit_number=$id_bit_number \n";
      next;
    }
    if ( $id_bit != $cmp_id_bit ){
      $search_direction = $id_bit;
    } else {
      # hä ? if this discrepancy if before the Last Discrepancy
      # on a previous next then pick the same as last time
      if ( $id_bit_number < $owx_LastDiscrepancy ){
        if (($owx_ROM_ID[$rom_byte_number] & $rom_byte_mask) > 0){
          $search_direction = 1;
        } else {
          $search_direction = 0;
        }
      } else {
        # if equal to last pick 1, if not then pick 0
        if ($id_bit_number == $owx_LastDiscrepancy){
          $search_direction = 1;
        } else {
          $search_direction = 0;
        }   
      }
      # if 0 was picked then record its position in LastZero
      if ($search_direction == 0){
        $last_zero = $id_bit_number;
        # check for Last discrepancy in family
        if ($last_zero < 9) {
          $owx_LastFamilyDiscrepancy = $last_zero;
        }
      }
    }
    # print "search_direction = $search_direction, last_zero=$last_zero\n";
    # set or clear the bit in the ROM byte rom_byte_number
    # with mask rom_byte_mask
    #print "ROM byte mask = $rom_byte_mask, search_direction = $search_direction\n";
    if ( $search_direction == 1){
      $owx_ROM_ID[$rom_byte_number] |= $rom_byte_mask;
    } else {
      $owx_ROM_ID[$rom_byte_number] &= ~$rom_byte_mask;
    }
    # serial number search direction write bit
    $response = OWX_WriteBit_9097($hash,$search_direction);
    # increment the byte counter id_bit_number
    # and shift the mask rom_byte_mask
    $id_bit_number++;
    $rom_byte_mask <<= 1;
    #-- if the mask is 0 then go to new rom_byte_number and
    if ($rom_byte_mask == 256){
      $rom_byte_number++;
      $rom_byte_mask = 1;
    } 
    $owx_LastDiscrepancy = $last_zero;
  }
  return 1; 
}

########################################################################################
# 
# OWX_TouchBit_9097 - Write/Read 1 bit from 1-wire bus  (Fig. 5-8 from Maxim AN 214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub OWX_TouchBit_9097 ($$) {
  my ($hash,$bit) = @_;
  
  my $sp1;
  #-- set baud rate to 115200 and query!!!
  if( $bit == 1 ){
    $sp1="\xFF";
  } else {
    $sp1="\x00";
  }
  $owx_baud=115200;
  my $res=OWX_Query_9097($hash,$sp1);
  $owx_baud=9600;
  #-- process result
  my $sp2=substr($res,0,1);
  if( $sp1 eq $sp2 ){
    return 1;
  }else {
    return 0;
  }
}

########################################################################################
# 
# OWX_TouchByte_9097 - Write/Read 8 bit from 1-wire bus 
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub OWX_TouchByte_9097 ($$) {
  my ($hash,$byte) = @_;
  
  my $loop;
  my $result=0;
  my $bytein=$byte;
  
  for( $loop=0; $loop < 8; $loop++ ){
    #-- shift result to get ready for the next bit
    $result >>=1;
    #-- if sending a 1 then read a bit else write 0
    if( $byte & 0x01 ){
      if( OWX_ReadBit_9097($hash) ){
        $result |= 0x80;
      }
    } else {
      OWX_WriteBit_9097($hash,0);
    }
    $byte >>= 1;
  }
  #print "-----------------------\n";
  #printf "Sending byte /%02x/\n",$bytein;
  #printf "Receiving byte /%02x/\n",$result;
  #print "-----------------------\n";
  return $result;
}

########################################################################################
# 
# OWX_WriteBit_9097 - Write 1 bit to 1-wire bus  (Fig. 7/8 from Maxim AN 214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub OWX_WriteBit_9097 ($$) {
  my ($hash,$bit) = @_;
  
  my $sp1;
  #-- set baud rate to 115200 and query!!!
  if( $bit ==1 ){
    $sp1="\xFF";
  } else {
    $sp1="\x00";
  }
  $owx_baud=115200;
  my $res=OWX_Query_9097($hash,$sp1);
  $owx_baud=9600;
  #-- process result
  if( substr($res,0,1) eq $sp1 ){
    return 1;
  } else {
    return 0;
  } 
}

1;
