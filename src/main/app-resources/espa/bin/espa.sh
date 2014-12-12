#!/bin/bash
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
if [ -z "$band" ]
	then
	band="sr"
elif [ $band != $TOA_BAND ]
	then
	band="sr"
fi

# retrieve the spectral indices
indices="`ciop-getparam spectral_indices`"

# rgb bands
rgb_bands="`ciop-getparam rgb`"
IFS=',' read -a array <<< "$rgb_bands"
if [ ${#array[@]}==3 ]
	then
	dorgb=1
	red=${array[0]}
	green=${array[1]}
	blue=${array[2]}
fi

mkdir -p $TMPDIR/ledaps

# symbolic link to common data files
mkdir -p $TMPDIR/ledaps/data
ln -s /usr/local/ledaps/data/CMGDEM.hdf $TMPDIR/ledaps/data/CMGDEM.hdf
mkdir -p $TMPDIR/ledaps/data/L5_TM
ln -s /usr/local/ledaps/data/L5_TM/gnew.dat $TMPDIR/ledaps/data/L5_TM/gnew.dat
ln -s /usr/local/ledaps/data/L5_TM/gold_2003.dat $TMPDIR/ledaps/data/L5_TM/gold_2003.dat
ln -s /usr/local/ledaps/data/L5_TM/gold.dat $TMPDIR/ledaps/data/L5_TM/gold.dat

# execute login 
curl -k -XPOST -c cookie --data "username=$USERNAME&password=$PASSWORD&rememberMe=1" $EARTHEXPLORER

while read input
do

	ciop-log "INFO" "read $input file"
    echo $input" read"

	DIRS=(${input//\// })
	datasetfilename=${DIRS[${#DIRS[@]} - 2]}
	DIRS=(${datasetfilename//:// })
	datasetfilename=${DIRS[${#DIRS[@]} - 1]}

	year=${datasetfilename:9:4}
	day=${datasetfilename:13:3}

	# build the direcotry  for the auxiliary files
	auxStartStop=`date --date="01/01/$year + $day days 1 day ago" +%Y-%m-%d`
	params='?start='$auxStartStop'&stop='$auxStartStop
	
	mkdir -p $TMPDIR/data
	mkdir -p $TMPDIR/data/$datasetfilename

    link=`ciop-casmeta -f "dclite4g:onlineResource" "$input"`
    ciop-log "INFO" "retrieve link = $link"   

    retrieved=`curl -L -b  cookie $link > $TMPDIR/data/$datasetfilename.tar.gz`
    ciop-log "INFO" "retrieved $datasetfilename.tar.gz file"

	ciop-log "INFO" "untar $datasetfilename file"
	tar xzf $TMPDIR/data/$datasetfilename.tar.gz -C $TMPDIR/data/$datasetfilename/
	
	ciop-log "INFO" "saving auxiliary file "$ledaps_reanalysis$params
	reanalysis_folder=$LEDAPS_AUX_DIR/REANALYSIS/RE_$year
	ciop-log "INFO" "creating $reanalysis_folder folder"
	mkdir -p $reanalysis_folder
	reanalysis=`ciop-copy -O $reanalysis_folder $ledaps_reanalysis$params`

	ciop-log "INFO" "saving auxiliary file "$ledaps_eptoms$params
	ozone_folder=$LEDAPS_AUX_DIR/EP_TOMS/ozone_$year
	ciop-log "INFO" "creating $ozone_folder folder"
	mkdir -p $ozone_folder
	ozone=`ciop-copy -O $ozone_folder $ledaps_eptoms$params`
	
	cd $TMPDIR/data/$datasetfilename

	ciop-log "INFO" "Execute conversion convert_lpgs_to_espa --mtl="$datasetfilename$mtl" --xml="$datasetfilename$xml
	convert_lpgs_to_espa --mtl=$datasetfilename$mtl --xml=$datasetfilename$xml

	ciop-log "INFO" "Start computing on $datasetfilename$xml"
	do_ledaps.py -f $datasetfilename$xml

	ciop-log "INFO" "Spectral indices computing"
	indicesParameters=" "
	IFS=',' read -a array <<< "$indices"
    for element in "${array[@]}"
    do
    	indicesParameters+="--$element " 
    done
    
    ciop-log "INFO" "Spectral indices parameters $indicesParameters"
    indicesParameters=$indicesParameters | sed -e 's/^ *//' -e 's/ *$//'
    
    ciop-log "INFO" "Executing: spectral_indices --xml=$datasetfilename$xml $indicesParameters"
	spectral_indices --xml=$datasetfilename$xml $indicesParameters

	mkdir -p $TMPDIR/data/$datasetfilename/$datasetfilename
	# build rgb file
	if [ $dorgb==1 ]	
		then
		convert_espa_to_gtif --xml=$datasetfilename$xml --gtif=$datasetfilename


		redBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_sr_band"$red.tif
		greenBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_sr_band"$green.tif
		blueBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_sr_band"$blue.tif
		if [ $band != $TOA_BAND ]
			then
			echo "Creating rgb from atmospheric correction analysis"
			ciop-log "INFO" "Creating rgb from atmospheric correction analysis"
			redBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_toa_band"$red.tif
			greenBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_toa_band"$green.tif
			blueBand=$TMPDIR/data/$datasetfilename/$datasetfilename"_toa_band"$blue.tif
		else
			echo "Creating rgb from sr analysis"
			ciop-log "INFO" "Creating rgb from sr analysis"
		fi
		#ciop-log "INFO" "Using redBand=$redBand"
		#ciop-log "INFO" "Using greenBand=$greenBand"
		#ciop-log "INFO" "Using blueBand=$blueBand"
		
		vrtFile=$TMPDIR/data/$datasetfilename/$datasetfilename.vrt
		pngFile=$TMPDIR/data/$datasetfilename/$datasetfilename.png
		gdalbuildvrt $vrtFile -separate $redBand $greenBand $blueBand
		gdal_translate -of PNG $vrtFile $pngFile
		echo "saving $pngFile file "
		cp $TMPDIR/data/$datasetfilename/$pngFile $TMPDIR/data/$datasetfilename/$datasetfilename/
	fi
	
	# save image files 
	echo "saving all processed image file "
	cp *_sr_*hdr $TMPDIR/data/$datasetfilename/$datasetfilename/
	cp *_sr_*img $TMPDIR/data/$datasetfilename/$datasetfilename/
	cp *_toa_*hdr $TMPDIR/data/$datasetfilename/$datasetfilename/
	cp *_toa_*img $TMPDIR/data/$datasetfilename/$datasetfilename/
	
	# publish all data
	ciop-publish -m -r $TMPDIR/data/$datasetfilename/$datasetfilename
	ciop-log "INFO" "$filename computation done. Data saved"

done	

exit 0