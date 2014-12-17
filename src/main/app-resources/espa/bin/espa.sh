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
    $ERR_NOCEOS) msg="CEOS product not retrieved";;
    $ERR_NOSLAVEFILE) msg="Slave not retrieved to local node";;
    *) msg="Unknown error";;
  esac

  [ "$retval" != "0" ] && {
    ciop-publish -m -r $TMPDIR/*.log;
    ciop-log "ERROR" "Error $retval - $msg, processing aborted"; } || { ciop-log "INFO" "$msg"; }
  exit $retval
}
trap cleanExit EXIT

set -x
# Landsat 5 process. ESPA alghoritms test
# add /usr/local/bin to the PATH
export PATH=$PATH:/usr/local/bin
# set the ledaps_aux_dir directory
export LEDAPS_AUX_DIR=$TMPDIR/ledaps

# exit code
ERR_NOINPUT=1

# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

mtl=_MTL.txt
xml=.xml
txt=.txt
lndcal=lndcal.
lndsr=ldsr.
TOA_BAND=toa
dorgb=0
EARTHEXPLORER=https://earthexplorer.usgs.gov/login/


# retrieve the eptoms catalogue for auxiliay files
ledaps_eptoms="`ciop-getparam ledaps_eptoms`"
# retrieve the reanalysis catalogue for auxiliay files
ledaps_reanalysis="`ciop-getparam ledaps_reanalysis`"
# retrieve EARTHEXPLORER credentials
USERNAME="`ciop-getparam user`"
PASSWORD="`ciop-getparam password`"

# retrieve the band type (TOA or SR)
band="`ciop-getparam toa_or_sr`"
#if [ -z "$band" ]
#	then
#	band="sr"
#elif [ $band != $TOA_BAND ]
#	then
#	band="sr"
#fi

[ -z "$band" ] && band="sr"
[ "$band" != "sr" ] && [ "$band" != "toa" ] && band="sr" 

# retrieve the spectral indices
indices="`ciop-getparam spectral_indices`"
[ -n "$indices" ] && indicesParameters=`echo "$indices" | tr "," "\n" | sed 's/^/ --/' | tr "\n" " "`

# rgb bands
red=""
rgb_bands="`ciop-getparam rgb`"
IFS=',' read -r red green blue <<< "$rgb_bands"
[ -n $red ] && dorgb=1


#IFS=',' read -a array <<< "$rgb_bands"
#if [ ${#array[@]}==3 ]
#	then
#	dorgb=1
#	red=${array[0]}
#	green=${array[1]}
#	blue=${array[2]}
#fi

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

while read input
do

  ciop-log "INFO" "Processing $input"

  datasetfilename="`ciop-casmeta -f "dc:identifier" $input | sed 's/.*://'`"

  auxStartDate="`ciop-casmeta -f "ical:dtstart" $input | tr -d "Z" | xargs -I {} date -d {} +%Y-%m-%d`"
  auxStopDate="`ciop-casmeta -f "ical:dtend" $input | tr -d "Z" | xargs -I {} date -d {} +%Y-%m-%d`"  
  params='?start='$auxStartDate'&stop='$auxStopDate
  year="`echo $auxStartDate | cut -c 1-4`" 
 
  # build the directory for the data and auxiliary files
  mkdir -p $TMPDIR/data
  mkdir -p $TMPDIR/data/$datasetfilename
	
  ciop-log "INFO" "Getting auxiliary file $ledaps_reanalysis$params"
  reanalysis_folder=$LEDAPS_AUX_DIR/REANALYSIS/RE_$year
  mkdir -p $reanalysis_folder
  reanalysis=`ciop-copy -O $reanalysis_folder $ledaps_reanalysis$params`
  res=$?
  [ "$res" != "0" ] && exit $ERR_NCEP_DOWNLOAD

  ciop-log "INFO" "Getting auxiliary file "$ledaps_eptoms$params
  ozone_folder=$LEDAPS_AUX_DIR/EP_TOMS/ozone_$year
  mkdir -p $ozone_folder
  ozone=`ciop-copy -O $ozone_folder $ledaps_eptoms$params`
  res=$?
  [ "$res" != "0" ] && exit $ERR_TOMS_DOWNLOAD

  # Download the Landsat product
  resource=`ciop-casmeta -f "dclite4g:onlineResource" "$input"`
  ciop-log "INFO" "retrieve Landsat product from $resource"

  retrieved=`curl -s -L -b  cookie $resource > $TMPDIR/data/$datasetfilename.tar.gz`
  res=$?
  [ "$res" != "0" ] && exit $ERR_LS_DOWNLOAD
 
  ciop-log "INFO" "retrieved $datasetfilename.tar.gz file, extracting"
  ciop-log "INFO" "untar $datasetfilename file"
  tar xzf $TMPDIR/data/$datasetfilename.tar.gz -C $TMPDIR/data/$datasetfilename/

  cd $TMPDIR/data/$datasetfilename

  # ESPA
  ciop-log "INFO" "Execute conversion espa format"
  convert_lpgs_to_espa --mtl=$datasetfilename$mtl --xml=$datasetfilename$xml &> $TMPDIR/convert_${datasetfilename}.log
  res=$?
  [ "$res" != "0" ] && exit $EXIT_CONVERT_ESPA

  ciop-log "INFO" "Start computing on $datasetfilename$xml"
  do_ledaps.py -f $datasetfilename$xml &> $TMPDIR/do_ledaps_${datasetfilename}.log
  res=$?
  [ "$res" != "0" ] && exit $ERR_LEDAPS

  # process the vegetation indexes	
  if [ -n "$indices" ]
  then
    ciop-log "INFO" "Spectral indices computing of $indices"
    spectral_indices --xml=$datasetfilename$xml $indicesParameters &> $TMPDIR/indices_${datasetfilename}.log
    res=$?
    [ "$res" != "0" ] && exit $ERR_INDICES
  fi

  mkdir -p $TMPDIR/data/$datasetfilename/$datasetfilename

  convert_espa_to_gtif --xml=$datasetfilename$xml --gtif=$datasetfilename &> $TMPDIR/espa_gtif_${datasetfilename}.log
  res=$?
  [ "$res" != "0" ] && exit $ERR_GEOCODE
  
  # build rgb file
  if [ $dorgb==1 ]	
  then
  
    ciop-log "INFO" "Creating rgb from ${band} analysis"
    redBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_${band}_band"$red.tif
    greenBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_${band}_band"$green.tif
    blueBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_${band}_band"$blue.tif
		
    vrtFile=$TMPDIR/data/$datasetfilename/$datasetfilename.vrt
    pngFile=$TMPDIR/data/$datasetfilename/${datasetfilename}_${band}.png
    gdalbuildvrt $vrtFile -separate $redBand $greenBand $blueBand
    res=$?
    [ "$res" != "0" ] && exit $ERR_GDAL_VRT

    gdal_translate -scale 0 32767 0 255 -of PNG -ot Byte $vrtFile $pngFile
    res=$?
    [ "$res" != "0" ] && exit $ERR_GDAL_TL_PNG

    cp $pngFile $TMPDIR/data/$datasetfilename/$datasetfilename/
  fi
	
  # save image files 
  echo "saving all processed image file "
  mv *_sr_*hdr $TMPDIR/data/$datasetfilename/$datasetfilename/
  mv *_sr_*img $TMPDIR/data/$datasetfilename/$datasetfilename/

  mv *_toa_*hdr $TMPDIR/data/$datasetfilename/$datasetfilename/
  mv *_toa_*img $TMPDIR/data/$datasetfilename/$datasetfilename/

  # publish all data
  ciop-publish -m -r $TMPDIR/data/$datasetfilename/$datasetfilename
  ciop-publish -m -r $TMPDIR/*.log
  ciop-log "INFO" "$filename computation done. Data saved"

  # clean up
  rm -f $TMPDIR/*.log
  rm -fr $TMPDIR/data
done
	

exit 0
