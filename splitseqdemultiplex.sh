#$ -V -cwd -j y -o -/home/ranump/ -m e -M ranump@email.chop.edu -q all.q -l h_vmem=5G -l m_mem_free=5G -pe smp 24
#!/bin/bash

# Provide the number of cores for multiplex steps
numcores="24"
minreadspercell="10" # this is a filesize 1000 = 1kb.  This helps to reduce excessive runtimes due to an abundance of low read count cells.
minlinesperfastq=$(($minreadspercell * 4))
echo "minimum reads per cell set to $minreadspercell" > splitseq_demultiplexing_runlog.txt
echo "minimum lines per cell is set to $minlinesperfastq" > splitseq_demultiplexing_runlog.txt

# Provide the filenames of the .csv files that contain the barcode sequences. These files should be located in the working directory.
ROUND1="Round1_barcodes_new3.txt"
ROUND2="Round2_barcodes_new3.txt"
ROUND3="Round3_barcodes_new3.txt"

# Provide the filenames of the .fastq files of interest. For this experiment paired end reads are required.
FASTQ_F="SRR6750041_1_minimedtest.fastq"
FASTQ_R="SRR6750041_2_minimedtest.fastq"

# Add the barcode sequences to a bash array.
declare -a ROUND1_BARCODES=( $(cut -b 1- $ROUND1) )
#printf "%s\n" "${ROUND1_BARCODES[@]}"

declare -a ROUND2_BARCODES=( $(cut -b 1- $ROUND2) )
#printf "%s\n" "${ROUND2_BARCODES[@]}"

declare -a ROUND3_BARCODES=( $(cut -b 1- $ROUND3) )
#printf "%s\n" "${ROUND3_BARCODES[@]}"

# Initialize the counter
count=1

# Log current time
now=$(date +"%T")
echo "Current time : $now" > splitseq_demultiplexing_runlog.txt 

# Make folder for results2 files
rm -r results2
mkdir results2
touch results2/emptyfile.txt

#######################################
# STEP 1: Demultiplex using barcodes  #
#######################################
# Search for the barcode in the sample reads file
# Use a for loop to iterate a search for each barcode.  If a match for the first barcode is found search for a match for a second barcode. If a match for the second barcode is found search through the third list of barcodes.

# Generate a progress message
now=$(date +"%T")
echo "Beginning STEP1: Demultiplex using barcodes. Current time : $now" >> splitseq_demultiplexing_runlog.txt

# Clean up by removing results2 files that may have been generated by a previous run.
rm -r ROUND*

# Begin the set of nested loops that searches for every possible barcode. We begin by looking for ROUND1 barcodes 
for barcode1 in "${ROUND1_BARCODES[@]}";
    do
    grep -F -B 1 -A 2 "$barcode1" $FASTQ_R > ROUND1_MATCH.fastq
   # echo barcode1.is.$barcode1
   # find results2/ -size 0 -delete 
    
        if [ -s ROUND1_MATCH.fastq ]
        then
            
            # Now we will look for the presence of ROUND2 barcodes in our reads containing barcodes from the previous step
            for barcode2 in "${ROUND2_BARCODES[@]}";
            do
            grep -F -B 1 -A 2 "$barcode2" ROUND1_MATCH.fastq > ROUND2_MATCH.fastq
               
                if [ -s ROUND2_MATCH.fastq ]
                then

                    # Now we will look for the presence of ROUND3 barcodes in our reads containing barcodes from the previous step 
                    grepfunction() {
                    grep -F -B 1 -A 2 "$1" ./ROUND2_MATCH.fastq | sed '/^--/d'
                    }
                    export -f grepfunction

                    parallel -j $numcores "grepfunction {} > ./results2/$barcode1-$barcode2-{}.fastq" ::: "${ROUND3_BARCODES[@]}"
                fi
            done
        fi
    done

# Create a function that to remove files under the specified minimum number of lines set by the user
removebylinesfunction() {
find "$1" -type f |
while read f; do
	i=0
	while read line; do
		i=$((i+1))
		[ $i -eq $minlinesperfastq ] && continue 2
	done < "$f"
	printf %s\\n "$f"
done |
xargs rm -f
}
export -f removebylinesfunction


# Run the function to remove .fastq files containing fewer than the minimum number of lines
removelinesfunction ./results2

#find results2/ -size -1k -delete

rm ROUND*

##########################################################
# STEP 2: For every cell find matching paired end reads  #
##########################################################
# Generate a progress message
now=$(date +"%T")
echo "Beginning STEP2: Finding read mate pairs. Current time : $now" >> splitseq_demultiplexing_runlog.txt

# Now we need to collect the other read pair. To do this we can collect read IDs from the results2 files we generated in step one.
# Generate an array of cell filenames
declare -a cells=( $(ls results2/) )

# Parallelize mate pair finding
for cell in "${cells[@]}";
    do 
    declare -a readID=( $(grep -Eo '^@[^ ]+' results2/$cell) ) 
       
        grepfunction2() {
        grep -F -A 3 "$1 " $2 | sed '/^--/d'
        }
        export -f grepfunction2
        
        {
        parallel -j $numcores -k "grepfunction2 {} $FASTQ_F >> results2/$cell.MATEPAIR" ::: "${readID[@]}" # Write the mate paired reads to a file
        } &> /dev/null
    done

# Eliminate any reads without a matepair
for cell in "${cells[@]}";
    do
    declare -a readID=( $(grep -Eo '^@[^ ]+' results2/$cell.MATEPAIR) )

        grepfunction2() {
        grep -F -A 3 "$1 " $2 | sed '/^--/d'
        }
        export -f grepfunction2

        {
        parallel -j $numcores -k "grepfunction2 {} $FASTQ_R >> results2/$cell.MATEPAIR.R" ::: "${readID[@]}" # Write the mate paired reads to a file
        } &> /dev/null
    done


########################
# STEP 3: Extract UMIs #
########################
# Generate a progress message
now=$(date +"%T")
echo "Beginning STEP3: Extracting UMIs. Current time : $now" >> splitseq_demultiplexing_runlog.txt

rm -r results2_UMI
mkdir results2_UMI

# Parallelize UMI extraction
{
#parallel -j $numcores 'fastp -i {} -o results_UMI/{/}.read2.fastq -U --umi_loc=read1 --umi_len=10' ::: results/*.fastq
parallel -j $numcores 'umi_tools extract -I {}.MATEPAIR.R --read2-in={}.MATEPAIR --bc-pattern=NNNNNNNNNN --log=processed.log --read2-out=results2_UMI/{/}' ::: results2/*.fastq
#parallel -j $numcores 'mv {} results2_UMI/cell_{#}.fastq' ::: results2_UMI/*.fastq
} &> /dev/null

#All finished
number_of_cells=$(ls -1 results2_UMI | wc -l)
now=$(date +"%T")
echo "a total of $number_of_cells cells were demultiplexed from the input .fastq" >> splitseq_demultiplexing_runlog.txt
echo "Current time : $now" >> splitseq_demultiplexing_runlog.txt
echo "all finished goodbye" >> splitseq_demultiplexing_runlog.txt
