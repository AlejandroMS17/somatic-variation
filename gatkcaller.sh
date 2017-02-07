#!usr/bin/bash
##TODO: REMOVE ALIGNMENT COMPONENTS, UPDATE DOCS + VARIABLES
#aligntoref.sh reference.fasta data.bam
#Takes reference and aligns all .fastq files in any subdirectory and calls SNPs with GATK.
#requires samtools, picard-tools, the GATK, and bowtie2

#http://tldp.org/LDP/abs/html/string-manipulation.html is a great guide for manipulating strings in bash
USAGE="Usage: $0 [-t THREADS] [-p PICARD_CMD] [-d TMPDIR] [-g  GATK_PATH] [-b BEDFILE] [-o OUTFILE] -r reference.fasta -i data.bam"

#Here are some things you might want to change:
PICARD="picard" #How do I call picard on this system?
GATK=~/bin/GenomeAnalysisTK.jar #Location of your GATK jar
CORES=48
TMPOPTION=""
OUTFILE=/dev/stdout
NUMNS=30
BEDFILE=""
REFERENCEFILE=""
FILEIN=""
trap "exit 1" ERR

while getopts :t:p:g:d:b:o:r:i:h opt; do
	case $opt in
		t)
			CORES=$OPTARG
			;;
		p)
			PICARD=$OPTARG
			;;
		g)
			GATK=$OPTARG
			;;
		d)
			TMPOPTION=$OPTARG
			;;
		b)
			BEDFILE=$OPTARG
			;;
		o)
			OUTFILE=$OPTARG
			;;
		r)
			REFERENCEFILE=$OPTARG
			;;
		i)
			FILEIN=$OPTARG
			;;
		h)
			echo $USAGE >&2
			exit 1
			;;
	    \?)
			echo "Invalid option: -$OPTARG" >&2
			echo $USAGE >&2
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument." >&2
			exit 1
			;;
	esac
done

shift $((OPTIND-1))

if [ $# -ne 0 ]; then			#if we forget arguments
	echo $USAGE >&2	#remind us
	exit 1				#and exit with error
fi

if [ "$REFERENCEFILE" == "" ]; then
	echo $USAGE >&2
	echo "Reference file required." >&2
	exit 1
fi

if [ "FILEIN" == "" ]; then
	echo $USAGE >&2
	echo "Input file required." >&2
	exit 1
fi


TMPDIR=$(mktemp -d --tmpdir=$TMPOPTION gatkcaller_tmp_XXXXXX)
trap "rm -rf $TMPDIR" EXIT INT TERM HUP

if [ "$BEDFILE" != "" ]; then
	BEDFILE=$(echo -XL $BEDFILE)
fi


###Below uses GATK to do some analysis.
DEDUPLIFIEDBAM=$(mktemp --tmpdir=$TMPDIR --suffix=.bam dedup_XXX)
METRICFILE=$(mktemp --tmpdir=$TMPDIR --suffix=.txt metrics_XXX)
REFERENCEDICT=${REFERENCEFILE%.*}.dict
FULLINTERVALS=$(mktemp --tmpdir=$TMPDIR --suffix=.interval_list fullIntervals_XXX)
SCATTEREDINTERVALDIR=$(mktemp -d --tmpdir=$TMPDIR scatteredIntervals_XXXXXX)
SCATTEREDFIRSTCALLDIR=$(mktemp -d --tmpdir=$TMPDIR scattered_first_calls_XXX)
SUFFIXES=$(seq -f %02.0f 0 $((CORES-1)))
SCATTEREDFIRSTCALLS=$(echo $SUFFIXES | tr ' ' '\n' | xargs -n 1 -i mktemp --tmpdir=$SCATTEREDFIRSTCALLDIR --suffix=.vcf first_calls_{}_XXXXXX)
CMDFIRSTCALLS=$(echo $SCATTEREDFIRSTCALLS | tr ' ' '\n' | xargs -i echo -V {})
JOINEDFIRSTCALLS=$(mktemp --tmpdir=$TMPDIR --suffix=.vcf joined_first_calls_XXX)
RECALIBRATEDBAM=$(mktemp --tmpdir=$TMPDIR --suffix=.bam recal_XXX)
SCATTEREDOUTCALLDIR=$(mktemp -d --tmpdir=$TMPDIR scattered_output_calls_XXX)
SCATTEREDOUTCALLS=$(echo $SUFFIXES | tr ' ' '\n' | xargs -n 1 -i mktemp --tmpdir=$SCATTEREDOUTCALLDIR --suffix=.vcf out_call_{}_XXXXXX)
CMDOUTCALLS=$(echo $SCATTEREDOUTCALLS | tr ' ' '\n' | xargs -i echo -V {})
RECALDATATABLE=$(mktemp --tmpdir=$TMPDIR --suffix=.table recal_data_XXX)


$PICARD MarkDuplicates INPUT=$FILEIN OUTPUT=$DEDUPLIFIEDBAM METRICS_FILE=$METRICFILE MAX_FILE_HANDLES_FOR_READ_ENDS_MAP=1000

if [ ! -e ${REFERENCEFILE}.fai ]; then
	samtools faidx $REFERENCEFILE
fi

if [ ! -e ${REFERENCEDICT} ]; then
	$PICARD CreateSequenceDictionary REFERENCE=${REFERENCEFILE} OUTPUT=${REFERENCEDICT}
fi

$PICARD BuildBamIndex INPUT=${DEDUPLIFIEDBAM}

#GATK TO RECALIBRATE QUAL SCORES + CALL VARIANTS
$PICARD ScatterIntervalsByNs R=${REFERENCEFILE} OT=ACGT MAX_TO_MERGE=${NUMNS} O=${FULLINTERVALS}
$PICARD IntervalListTools I=${FULLINTERVALS} SCATTER_COUNT=$CORES O=${SCATTEREDINTERVALDIR}
SCATTEREDINTERVALS=$(find ${SCATTEREDINTERVALDIR} -name '*.interval_list')
parallel --halt 2 java -jar ${GATK} -T HaplotypeCaller -R ${REFERENCEFILE} -I $DEDUPLIFIEDBAM -L {1} ${BEDFILE} -stand_call_conf 50 -ploidy 2 -o {2} ::: $SCATTEREDINTERVALS :::+ $SCATTEREDFIRSTCALLS
java -cp ${GATK} org.broadinstitute.gatk.tools.CatVariants -R ${REFERENCEFILE} --outputFile ${JOINEDFIRSTCALLS} ${CMDFIRSTCALLS} -assumeSorted
rm $SCATTEREDFIRSTCALLS
java -jar ${GATK} -T BaseRecalibrator -nct $CORES -I $DEDUPLIFIEDBAM -R ${REFERENCEFILE} ${BEDFILE} --knownSites $JOINEDFIRSTCALLS -o $RECALDATATABLE
rm $JOINEDFIRSTCALLS
java -jar ${GATK} -T PrintReads -nct $CORES -I $DEDUPLIFIEDBAM -R ${REFERENCEFILE} -BQSR $RECALDATATABLE -EOQ -o $RECALIBRATEDBAM
rm $DEDUPLIFIEDBAM $RECALDATATABLE
parallel --halt 2 java -jar ${GATK} -T HaplotypeCaller -R ${REFERENCEFILE} -I $RECALIBRATEDBAM -L {1} ${BEDFILE} -ploidy 2 -o {2} ::: $SCATTEREDINTERVALS :::+ $SCATTEREDOUTCALLS
rm $SCATTEREDINTERVALS $RECALIBRATEDBAM
java -cp ${GATK} org.broadinstitute.gatk.tools.CatVariants -R ${REFERENCEFILE} -assumeSorted --outputFile ${OUTFILE} ${CMDOUTCALLS}

exit 0
