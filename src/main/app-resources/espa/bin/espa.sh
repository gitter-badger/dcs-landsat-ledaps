#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_LS_DOWNLOAD=10
ERR_NCEP_DOWNLOAD=11
ERR_TOMS_DOWNLOAD=12
ERR_CONVERT_ESPA=20
ERR_LEDAPS=25
ERR_INDICES=30
ERR_GEOCODE=35
ERR_GDAL_VRT=40
ERR_GDAL_TL_PNG=45

# add a trap to exit gracefully
function cleanExit () {
  local retval=$?
  local msg=""
  case "$retval" in
    $SUCCESS) msg="Processing successfully concluded";;
    $ERR_NOMASTER) msg="Master reference not provided";;
    $ERR_NOMASTERWKT) msg="Master WKT not retrieved";;
    $ERR_NOMASTERFILE) msg="Master not retrieved to local node";;
    $ERR_NODEM) msg="DEM not retrieved";;
    $ERR_AUX) msg="Failed to retrieve auxiliary and/or orbital data";;
    $ERR_GEOCODE) msg="Failed to geocode products";;
    $ERR_NOSLAVEFILE) msg="Slave not retrieved to local node";;
    *) msg="Unknown error";;
  esac

  [ "$retval" != "0" ] && {
    ciop-publish -r $lsfolder/*.log;
    ciop-log "ERROR" "Error $retval - $msg, processing aborted"; } || { ciop-log "INFO" "$msg"; }
  exit $retval
}
trap cleanExit EXIT

#set -x
# Landsat 5 process. ESPA alghoritms test
# add /usr/local/bin to the PATH
export PATH=$PATH:/usr/local/bin
# set the ledaps_aux_dir directory
export LEDAPS_AUX_DIR=$TMPDIR/ledaps

# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

#TOA_BAND=toa
dorgb=0
doveg=0

EARTHEXPLORER=https://earthexplorer.usgs.gov/login/

# retrieve the eptoms catalogue for auxiliay files
ledaps_eptoms="`ciop-getparam ledaps_eptoms`"
# retrieve the reanalysis catalogue for auxiliay files
ledaps_reanalysis="`ciop-getparam ledaps_reanalysis`"
# retrieve EARTHEXPLORER credentials
USERNAME="`ciop-getparam user`"
PASSWORD="`ciop-getparam password`"

# retrieve the spectral indices
indices="`ciop-getparam spectral_indices`"
[ -n "$indices" ] && doveg=1

# rgb bands
rgb_bands="`ciop-getparam rgb`"
[ -n $rgb_bands ] && dorgb=1

mkdir -p $TMPDIR/ledaps

# symbolic link to common data files
mkdir -p $TMPDIR/ledaps/data
ln -s /usr/local/ledaps/data/CMGDEM.hdf $TMPDIR/ledaps/data/CMGDEM.hdf
mkdir -p $TMPDIR/ledaps/data/L5_TM
ln -s /usr/local/ledaps/data/L5_TM/gnew.dat $TMPDIR/ledaps/data/L5_TM/gnew.dat
ln -s /usr/local/ledaps/data/L5_TM/gold_2003.dat $TMPDIR/ledaps/data/L5_TM/gold_2003.dat
ln -s /usr/local/ledaps/data/L5_TM/gold.dat $TMPDIR/ledaps/data/L5_TM/gold.dat

# execute login 
curl -s -k -XPOST -c cookie --data "username=$USERNAME&password=$PASSWORD&rememberMe=1" $EARTHEXPLORER

function getAux() {
  local dataset=$1

  auxStartDate="`ciop-casmeta -f "ical:dtstart" $dataset | tr -d "Z" | xargs -I {} date -d {} +%Y-%m-%d`"
  auxStopDate="`ciop-casmeta -f "ical:dtend" $dataset | tr -d "Z" | xargs -I {} date -d {} +%Y-%m-%d`"
  year="`echo $auxStartDate | cut -c 1-4`"

  ciop-log "INFO" "Getting auxiliary file $ledaps_reanalysis$params"
  reanalysis_folder=$LEDAPS_AUX_DIR/REANALYSIS/RE_$year
  mkdir -p $reanalysis_folder
  reanalysis=`opensearch-client -f Rdf -p time:start=$auxStartDate -p time:end=$auxStopDate -p count=100 $ledaps_reanalysis enclosure | ciop-copy -O $reanalysis_folder -`
  res=$?
  [ "$res" != "0" ] && return $ERR_NCEP_DOWNLOAD

  ciop-log "INFO" "Getting auxiliary file "$ledaps_eptoms$params
  ozone_folder=$LEDAPS_AUX_DIR/EP_TOMS/ozone_$year
  mkdir -p $ozone_folder
  ozone=`opensearch-client -f Rdf -p time:start=$auxStartDate -p time:end=$auxStopDate -p count=100 $ledaps_eptoms enclosure | ciop-copy -O $ozone_folder -`
  res=$?
  [ "$res" != "0" ] && return $ERR_TOMS_DOWNLOAD
  return 0
}

function downloadLandsat() {
  # takes a reference to a catalogue entry $1
  # and downloads the product in folder $2
  # returns the name of the dataset
  # the product files are then found in $target/$datasetfilename
  local dataset=$1
  local target=$2
  datasetfilename="`ciop-casmeta -f "dc:identifier" $dataset | sed 's/.*://'`"
  mkdir -p $target/$datasetfilename

  resource=`ciop-casmeta -f "dclite4g:onlineResource" "$dataset"`
  ciop-log "INFO" "retrieve Landsat product from $resource"

  curl -s -L -b  cookie $resource > $target/$datasetfilename.tar.gz
  res=$?
  [ "$res" != "0" ] && return $ERR_LS_DOWNLOAD

  ciop-log "INFO" "retrieved $datasetfilename.tar.gz file, extracting"
  ciop-log "INFO" "untar $datasetfilename file"
  tar xzf $target/$datasetfilename.tar.gz -C $target/$datasetfilename/
  res=$?
  [ "$res" != "0" ] && return $ERR_LS_EXTRACT

  echo $datasetfilename
}

function lpgs2espa() {
  local lsname=$1
  # ESPA
  ciop-log "INFO" "Execute conversion espa format"
  convert_lpgs_to_espa --mtl=${lsname}_MTL.txt --xml=${lsname}.xml &> convert_${lsname}.log
  res=$?
  [ "$res" != "0" ] && return $EXIT_CONVERT_ESPA
  
  return 0
}

function ledaps() {
  local lsname=$1 
  ciop-log "INFO" "Start computing on ${lsname}"
  do_ledaps.py -f ${lsname}.xml &> do_ledaps_${lsname}.log
  res=$?
  [ "$res" != "0" ] && return $ERR_LEDAPS
 
  return 0
}

function vegindices() {
  local lsname=$1  
  local indices="$2"
  ciop-log "INFO" "Spectral indices computing of $indices"
  local indicesParameters=`echo "$indices" | tr "," "\n" | sed 's/^/ --/' | tr "\n" " "`
  spectral_indices --xml=${lsname}.xml $indicesParameters &> indices_${lsname}.log
  res=$?
  [ "$res" != "0" ] && return $ERR_INDICES

  return 0
}

function geocode() {
  local lsname=$1
  convert_espa_to_gtif --xml=${lsname}.xml --gtif=${lsname} &> espa_gtif_${lsname}.log
  res=$?
  [ "$res" != "0" ] && return $ERR_GEOCODE

  return 0
}

function rgb() {
  local lsname=$1
  local rgbbands=$2

  IFS=',' read -r red green blue <<< "$rgb_bands"

  for reflectype in `echo "sr,toa" | tr "," "\n"`
  do
    redBand=${lsname}_${reflectype}_band${red}.tif
    greenBand=${lsname}_${reflectype}_band${green}.tif
    blueBand=${lsname}_${reflectype}_band${blue}.tif

    vrtFile=${lsname}_${reflectype}.vrt
    pngFile=${lsname}_${reflectype}.png
    gdalbuildvrt $vrtFile -separate $redBand $greenBand $blueBand
    res=$?
    [ "$res" != "0" ] && return $ERR_GDAL_VRT

    gdal_translate -scale 0 32767 0 255 -of PNG -ot Byte $vrtFile $pngFile
    res=$?
    [ "$res" != "0" ] && return $ERR_GDAL_TL_PNG
  done
  
  return 0
}

target=$TMPDIR/data

while read input
do
  ciop-log "INFO" "Processing $input"

  datasetfilename="`ciop-casmeta -f "dc:identifier" $input | sed 's/.*://'`"

  getAux $input	
  res=$?
  [ "$res" != "0" ] && exit $res

  # Download the Landsat product
  lsname=`downloadLandsat $input $target`
  res=$?
  [ "$res" != "0" ] && exit $res
  
  lsfolder=$target/$lsname

  cd $lsfolder 

  # ESPA
  lpgs2espa $lsname
  res=$?
  [ "$res" != "0" ] && exit $res 

  # ledaps
  ledaps $lsname  
  res=$?
  [ "$res" != "0" ] && exit $res

  # process the vegetation indexes	
  if [ "$doveg" == "1" ]
  then 
    vegindices $lsname "$indices"
    res=$?
    [ "$res" != "0" ] && exit $res
  fi

  geocode $lsname 
  res=$?
  [ "$res" != "0" ] && exit $res
  
  # build rgb file
  if [ "$dorgb" == "1" ] 
  then
    ciop-log "INFO" "Creating rgb $rgb_bands"
    rgb $lsname $rgb_bands
    res=$?
    [ "$res" != "0" ] && exit $res
  fi
  	
  # save image files 
  ciop-log "INFO" "Publishing all processing results"
  # create the final folder for the results to publish
  mkdir -p $lsfolder/$lsname
  mv *.png *.log *_sr_*hdr *_sr_*img *_toa_*hdr *_toa_*img  $lsfolder/$lsname 

  # publish all data
  ciop-publish -m -r $lsfolder/$lsname 
  ciop-log "INFO" "$filename computation done. Data saved"

  # clean up
  rm -f $lsfolder
done
	
exit 0
