#! /usr/bin/env nextflow
import groovy.json.JsonSlurper
PROGRAM_NAME = workflow.manifest.name
VERSION = workflow.manifest.version
OUTDIR = "${params.outdir}/bactopia-tools/${PROGRAM_NAME}"
OVERWRITE = workflow.resume || params.force ? true : false
DOWNLOAD_PHYLOFLASH = false
SILVA_VERSION = false

// Validate parameters
if (params.version) print_version();
log.info "bactopia tools ${PROGRAM_NAME} - ${VERSION}"
if (params.help || workflow.commandLine.trim().endsWith(workflow.scriptName)) print_help();
check_input_params()
if (DOWNLOAD_PHYLOFLASH){
    print_silva_license()
}
samples = gather_sample_set(params.bactopia, params.exclude, params.include, params.sleep_time)

process download_phyloflash {
    publishDir "${params.phyloflash}", mode: "copy", overwrite: true, pattern: "ref/*"
    publishDir "${params.phyloflash}", mode: "copy", overwrite: true, pattern: "SILVA*"

    input:
    val phyloflash_path from params.phyloflash

    output:
    file("ref/*") optional true
    file("SILVA*") optional true
    file 'phyloflash-downloaded.txt' into PHYLOFLASH_CHECK
    
    shell:
    """
    if [ "!{DOWNLOAD_PHYLOFLASH}" == "true" ]; then
        printf 'yes\n' | phyloFlash_makedb.pl --remote --CPUs !{task.cpus}
        mv !{SILVA_VERSION}/* ./
    else
        echo "skipping phyloFlash database download"
    fi

    touch phyloflash-downloaded.txt
    """
}

process reconstruct_16s {
    publishDir "${OUTDIR}/samples", mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "${sample}/*"
    tag "${sample} - ${readlength}"

    input:
    set val(sample), val(single_end), file(fq), val(readlength), val(readlength_mod) from Channel.fromList(samples)
    file(phyloflash_check) from PHYLOFLASH_CHECK

    output:
    file "${sample}/*" 
    file "${sample}/${sample}.toalign.fasta" optional true into ALIGNMENT
    file "${sample}/${sample}.phyloFlash.json" optional true into SUMMARY

    shell:
    read = single_end ? "-read1 ${fq[0]}" : "-read1 ${fq[0]} -read2 ${fq[1]}"
    readlength = task.attempt > 1 ? readlength - (task.attempt * readlength_mod) : readlength
    """        
    mkdir !{sample}
    if [ "!{readlength}" -ge "50" ]; then 
        MULTI="0"
        phyloFlash.pl -dbhome "!{params.phyloflash}" !{read} -lib !{sample} \
                      -CPUs !{task.cpus} -readlength !{readlength} -taxlevel !{params.taxlevel}
        jsonify-phyloflash.py !{sample}.phyloFlash > !{sample}.phyloFlash.json
        mv !{sample}.* !{sample}

        if phyloflash-summary.py !{sample}/ | grep -q -c "WARNING: Multiple SSUs were assembled by SPAdes"; then
            MULTI="1"
        fi

        if [ "!{params.allow_multiple_16s}" == "true" ]; then
            MULTI="0"
        fi

        if [ "!{params.align_all}" == "true" ]; then 
            if [ -f "!{sample}/!{sample}.SSU.collection.fasta" ]; then
                if [ "\${MULTI}" -eq "0" ]; then
                    cp !{sample}/!{sample}.SSU.collection.fasta !{sample}/!{sample}.toalign.fasta
                else
                    echo "!{sample} contained multiple 16s genes." > !{sample}/!{sample}-multiple-16s.txt
                fi
            else
                echo "!{sample} failed SPAdes assembly." > !{sample}/!{sample}-spades-failed.txt
            fi
        else
            if [ -f "!{sample}/!{sample}.spades_rRNAs.final.fasta" ]; then
                if [ "\${MULTI}" -eq "0" ]; then
                    cp !{sample}/!{sample}.spades_rRNAs.final.fasta !{sample}/!{sample}.toalign.fasta
                else
                    echo "!{sample} contained multiple 16s genes." > !{sample}/!{sample}-multiple-16s.txt
                fi
            else 
                echo "!{sample} failed SPAdes assembly." > !{sample}/!{sample}-spades-failed.txt
            fi
        fi
    else
        echo "!{sample} not processed. Mean read length, !{readlength}bp, must be greater than 50bp for phyloFlash analysis." > !{sample}/!{sample}-unprocessed.txt
    fi
    """
}

process align_16s {
    publishDir "${OUTDIR}/alignment", mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "${params.prefix}-alignment.fasta"
    publishDir "${OUTDIR}/alignment", mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "${params.prefix}-matches.txt"
    
    input:
    file(fasta) from ALIGNMENT.collect()

    output:
    file "${params.prefix}-alignment.fasta" into TREE
    file "${params.prefix}-matches.txt"

    when:
    params.skip_phylogeny == false

    shell:
    """
    format-16s-fasta.py ./ --prefix !{params.prefix}
    mafft --thread !{task.cpus} !{params.mafft_opts} !{params.prefix}-merged.fasta > !{params.prefix}-alignment.fasta
    """
}

process create_phylogeny {
    publishDir OUTDIR, mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "iqtree/*"
    publishDir OUTDIR, mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "${params.prefix}.iqtree"

    input:
    file fasta from TREE

    output:
    file 'iqtree/*'
    file "${params.prefix}.iqtree"

    when:
    params.skip_phylogeny == false

    shell:
    bb = params.bb == 0 ? "" : "-bb ${params.bb}"
    alrt = params.alrt == 0 ? "" : "-alrt ${params.alrt}"
    """
    mkdir iqtree
    iqtree -s !{fasta} -m !{params.m} -nt !{task.cpus} -pre iqtree/16s \
           !{bb} !{alrt} -wbt -wbtl \
           -alninfo !{params.iqtree_opts}
    cp iqtree/16s.iqtree !{params.prefix}.iqtree
    """
}

process phyloflash_summary {
    publishDir OUTDIR, mode: "${params.publish_mode}", overwrite: OVERWRITE, pattern: "${params.prefix}-summary.txt"

    input:
    file(json) from SUMMARY.collect()

    output:
    file "${params.prefix}-summary.txt"

    shell:
    """
    phyloflash-summary.py ./ > !{params.prefix}-summary.txt
    """
}

workflow.onComplete {
    workDir = new File("${workflow.workDir}")
    workDirSize = toHumanString(workDir.directorySize())

    println """
    Bactopia Tool '${PROGRAM_NAME}' - Execution Summary
    ---------------------------
    Command Line    : ${workflow.commandLine}
    Resumed         : ${workflow.resume}
    Completed At    : ${workflow.complete}
    Duration        : ${workflow.duration}
    Success         : ${workflow.success}
    Exit Code       : ${workflow.exitStatus}
    Error Report    : ${workflow.errorReport ?: '-'}
    Launch Dir      : ${workflow.launchDir}
    Working Dir     : ${workflow.workDir} (Total Size: ${workDirSize})
    Working Dir Size: ${workDirSize}
    """
}

// Utility functions
def toHumanString(bytes) {
    // Thanks Niklaus
    // https://gist.github.com/nikbucher/9687112
    base = 1024L
    decimals = 3
    prefix = ['', 'K', 'M', 'G', 'T']
    int i = Math.log(bytes)/Math.log(base) as Integer
    i = (i >= prefix.size() ? prefix.size()-1 : i)
    return Math.round((bytes / base**i) * 10**decimals) / 10**decimals + prefix[i]
}

def print_version() {
    log.info "bactopia tools ${PROGRAM_NAME} - ${VERSION}"
    exit 0
}

def file_exists(file_name, parameter) {
    if (!file(file_name).exists()) {
        log.error('Invalid input ('+ parameter +'), please verify "' + file_name + '" exists.')
        return 1
    }
    return 0
}

def output_exists(outdir, force, resume) {
    if (!resume && !force) {
        if (file(OUTDIR).exists()) {
            files = file(OUTDIR).list()
            total_files = files.size()
            if (total_files == 1) {
                if (files[0] != 'bactopia-info') {
                    return 1
                }
            } else if (total_files > 1){
                return 1
            }
        }
    }
    return 0
}

def check_unknown_params() {
    valid_params = []
    error = 0
    new File("${baseDir}/conf/params.config").eachLine { line ->
        if (line.contains("=")) {
            valid_params << line.trim().split(" ")[0]
        }
    }

    params.each { k,v ->
        if (!valid_params.contains(k)) {
            if (k != "container-path") {
                log.error("'--${k}' is not a known parameter")
                error = 1
            }
        }
    }

    return error
}

def check_input_params() {
    // Check for unexpected paramaters
    error = check_unknown_params()

    if (params.bactopia) {
        error += file_exists(params.bactopia, '--bactopia')
    } else {
        log.error """
        The required '--bactopia' and/or '--phyloflash' parameter is missing, please check and try again.

        Required Parameters:
            --bactopia STR          Directory containing Bactopia analysis results for all samples.

            --phyloflash STR     Directory containing a pre-built phyloFlash database.
        """.stripIndent()
        error += 1
    }

    if (params.include) {
        error += file_exists(params.include, '--include')
    }
    
    if (params.exclude) {
        error += file_exists(params.exclude, '--exclude')
    } 

    if (file(params.phyloflash).exists() && params.download_phyloflash) {
        log.info """
            Found phyloFlash database at ${params.phyloflash}, but '--download_phyloflash'
            also given. Existing phyloFlash database will be over written with
            latest build. If this is error, please stop now.
        """.stripIndent()
        DOWNLOAD_PHYLOFLASH = true
    } else if (!file(params.phyloflash).exists() && params.download_phyloflash) {
        log.info("Latest phyloFlash database will be downloaded to ${params.phyloflash}")
        DOWNLOAD_PHYLOFLASH = true
    } else if (!file(params.phyloflash).exists()) {
        log.error """
            Please check that a phyloFlash database exists at ${params.phyloflash}. 
            Otherwise use '--download_phyloflash' to download the latest phyloFlash database
        """.stripIndent()
        error += 1
    }

    error += is_positive_integer(params.cpus, 'cpus')
    error += is_positive_integer(params.min_time, 'min_time')
    error += is_positive_integer(params.max_time, 'max_time')
    error += is_positive_integer(params.max_memory, 'max_memory')
    error += is_positive_integer(params.sleep_time, 'sleep_time')
    error += is_positive_integer(params.taxlevel, 'taxlevel')
    error += is_positive_integer(params.bb, 'bb')
    error += is_positive_integer(params.alrt, 'alrt')

    // Check for existing output directory
    if (output_exists(OUTDIR, params.force, workflow.resume)) {
        log.error("Output directory (${OUTDIR}) exists, Bactopia will not continue unless '--force' is used.")
        error += 1
    }

    if (!['dockerhub', 'github', 'quay'].contains(params.registry)) {
        log.error "Invalid registry (--registry ${params.registry}), must be 'dockerhub', " +
                    "'github' or 'quay'. Please correct to continue."
        error += 1
    }

    if (params.min_time > params.max_time) {
        log.error "The value for min_time (${params.min_time}) exceeds max_time (${params.max_time}), Please correct to continue."
        error += 1
    }

    // Check publish_mode
    ALLOWED_MODES = ['copy', 'copyNoFollow', 'link', 'rellink', 'symlink']
    if (!ALLOWED_MODES.contains(params.publish_mode)) {
        log.error("'${params.publish_mode}' is not a valid publish mode. Allowed modes are: ${ALLOWED_MODES}")
        error += 1
    }


    if (error > 0) {
        log.error('Cannot continue, please see --help for more information')
        exit 1
    }
}


def is_positive_integer(value, name) {
    error = 0
    if (value.getClass() == Integer) {
        if (value < 0) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not a positive integer.')
            error = 1
        }
    } else {
        if (!value.isInteger()) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not numeric.')
            error = 1
        } else if (value.toInteger() < 0) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not a positive integer.')
            error = 1
        }
    }
    return error
}

def is_sample_dir(sample, dir){
    return file("${dir}/${sample}/${sample}-genome-size.txt").exists()
}

def build_fastq_tuple(sample, dir) {
    def jsonSlurper = new JsonSlurper()
    se = "${dir}/${sample}/quality-control/${sample}.fastq.gz"
    pe1 = "${dir}/${sample}/quality-control/${sample}_R1.fastq.gz"
    pe2 = "${dir}/${sample}/quality-control/${sample}_R2.fastq.gz"
    single_end = false
    files = null
    json_stats = null
    if (file(se).exists()) {
        single_end = true
        json_stats = "${dir}/${sample}/quality-control/summary-final/${sample}-final.json"
        files = [file(se)]
    } else if (file(pe1).exists() && file(pe2).exists()) {
        json_stats = "${dir}/${sample}/quality-control/summary-final/${sample}_R1-final.json"
        files = [file(pe1), file(pe2)]
    } else {
        log.error("Could not locate FASTQs for ${sample}, please verify existence. Unable to continue.")
        exit 1
    }
    json_data = jsonSlurper.parse(new File(json_stats))
    // PhyloFlash using the same kmers for any read lengths > 134bp
    readlength = Math.min(134, Math.round(json_data['qc_stats']['read_mean'] - json_data['qc_stats']['read_std']))
    readlength_mod = Math.round(readlength * 0.10)
    return tuple(sample, single_end, files, readlength, readlength_mod)
}

def print_silva_license() {
    log.info "In order to use the SILVA database you must accept its license. "
    log.info "SILVA License:"
    log.info ""
    println file('https://ftp.arb-silva.de/current/LICENSE.txt').text
    log.info ""
    if (params.yes) {
        log.info "You have given '--yes' stating you accept the SILVA license."
        SILVA_VERSION = file('https://ftp.arb-silva.de/current/VERSION.txt').text.trim()
        log.info "The SILVA (${SILVA_VERSION}) will be used by phyloFlash."
    } else {
        log.error "Please use '--yes' to accept the SILVA license to continue."
        exit 1
    }

}

def gather_sample_set(bactopia_dir, exclude_list, include_list, sleep_time) {
    include_all = true
    inclusions = []
    exclusions = []
    IGNORE_LIST = ['.nextflow', 'bactopia-info', 'bactopia-tools', 'work',]
    if (include_list) {
        new File(include_list).eachLine { line -> 
            inclusions << line.trim()
        }
        include_all = false
        log.info "Including ${inclusions.size} samples for analysis"
    }
    else if (exclude_list) {
        new File(exclude_list).eachLine { line -> 
            exclusions << line.trim().split('\t')[0]
        }
        log.info "Excluding ${exclusions.size} samples from the analysis"
    }

    sample_list = []
    file(bactopia_dir).eachFile { item ->
        if( item.isDirectory() ) {
            sample = item.getName()
            if (!IGNORE_LIST.contains(sample)) {
                if (inclusions.contains(sample) || include_all) {
                    if (!exclusions.contains(sample)) {
                        if (is_sample_dir(sample, bactopia_dir)) {
                            sample_list << build_fastq_tuple(sample, bactopia_dir)
                        } else {
                            log.info "${sample} is missing genome size estimate file"
                        }
                    }
                }
            }
        }
    }

    log.info "Found ${sample_list.size} samples to process"
    if (sample_list.size == 0) {
        if (DOWNLOAD_PHYLOFLASH) {
            log.info "\nphyloFlash database download will proceed."
        } else {
            log.info "\nNothing to do, exiting..."
            exit 1
        }
    }

    log.info "\nIf this looks wrong, now's your chance to back out (CTRL+C 3 times)."
    log.info "Sleeping for ${sleep_time} seconds..."
    sleep(sleep_time * 1000)
    return sample_list
}


def print_help() {
    log.info"""
    Required Parameters:
        --bactopia STR          Directory containing Bactopia analysis results for all samples.

        --phyloflash STR     Directory containing a pre-built phyloFlash database.

    Optional Parameters:
        --include STR           A text file containing sample names to include in the
                                    analysis. The expected format is a single sample per line.

        --exclude STR           A text file containing sample names to exclude from the
                                    analysis. The expected format is a single sample per line.

        --prefix DIR            Prefix to use for final output files
                                    Default: ${params.prefix}

        --outdir DIR            Directory to write results to
                                    Default: ${params.outdir}

        --min_time INT          The minimum number of minutes a job should run before being halted.
                                    Default: ${params.min_time} minutes

        --max_time INT          The maximum number of minutes a job should run before being halted.
                                    Default: ${params.max_time} minutes

        --max_memory INT        The maximum amount of memory (Gb) allowed to a single process.
                                    Default: ${params.max_memory} Gb

        --cpus INT              Number of processors made available to a single
                                    process.
                                    Default: ${params.cpus}

    phyloFlash Related Parameters:
        --download_phyloflash   Download the latest phyloFlash database, even it exists.

        --yes                   You acknowledge SILVAs license.

        --taxlevel INT          Level in the taxonomy string to summarize read counts per taxon.
                                    Numeric and 1-based (i.e. "1" corresponds to "Domain").
                                    Default: ${params.taxlevel}

        --phyloflash_opts STR   Extra phyloFlash options in quotes.
                                    Default: ''

        --allow_multiple_16s    Include samples with multiple reconstructed 16S genes. Due to
                                    high sequence similarity in true multi-copy 16S genes, it
                                    is unlikely each copy will be reconstructed, instead only
                                    one. In order to get more than one reconstructed 16S gene
                                    there must be a significant difference in the sequence
                                    identity. As a consequence, any samples that have multiple 
                                    16S genes reconstructed contain multiple different species
                                    within their sequencing.
                                    Default: Exclude samples with multiple 16S genes


    MAFFT Related Parameters:
        --align_all             Include reconstructed 16S genes as well as the corresponding
                                    reference 16S genes in the alignment.

        --mafft_opts STR        MAFFT options to include (in quotes).
                                    Default: ''

    IQ-TREE Related Parameters:
        --skip_phylogeny        Skip the creation a core-genome based phylogeny

        --m STR                 Substitution model name
                                    Default: ${params.m}

        --bb INT                Ultrafast bootstrap replicates
                                    Default: ${params.bb}

        --alrt INT              SH-like approximate likelihood ratio test replicates
                                    Default: ${params.alrt}

        --asr                   Ancestral state reconstruction by empirical Bayes
                                    Default: ${params.asr}

        --iqtree_opts STR       Extra IQ-TREE options in quotes.
                                    Default: ''

    Nextflow Related Parameters:
        --condadir DIR          Directory to Nextflow should use for Conda environments
                                    Default: Bactopia's Nextflow directory

        --registry STR          Docker registry to pull containers from. 
                                    Available options: dockerhub, quay, or github
                                    Default: dockerhub

        --singularity_cache STR Directory where remote Singularity images are stored. If using a cluster, it must
                                    be accessible from all compute nodes.
                                    Default: NXF_SINGULARITY_CACHEDIR evironment variable, otherwise ${params.singularity_cache}

        --queue STR             The name of the queue(s) to be used by a job scheduler (e.g. AWS Batch or SLURM).
                                    If using multiple queues, please seperate queues by a comma without spaces.
                                    Default: ${params.queue}

        --disable_scratch       All intermediate files created on worker nodes of will be transferred to the head node.
                                    Default: Only result files are transferred back

        --cleanup_workdir       After Bactopia is successfully executed, the work directory will be deleted.
                                    Warning: by doing this you lose the ability to resume workflows.
                           
        --publish_mode          Set Nextflow's method for publishing output files. Allowed methods are:
                                    'copy' (default)    Copies the output files into the published directory.

                                    'copyNoFollow' Copies the output files into the published directory 
                                                   without following symlinks ie. copies the links themselves.

                                    'link'    Creates a hard link in the published directory for each 
                                              process output file.

                                    'rellink' Creates a relative symbolic link in the published directory
                                              for each process output file.

                                    'symlink' Creates an absolute symbolic link in the published directory 
                                              for each process output file.

                                    Default: ${params.publish_mode}

        --force                 Nextflow will overwrite existing output files.
                                    Default: ${params.force}

        --sleep_time            After reading datases, the amount of time (seconds) Nextflow
                                    will wait before execution.
                                    Default: ${params.sleep_time} seconds

        --nfconfig STR          A Nextflow compatible config file for custom profiles. This allows 
                                    you to create profiles specific to your environment (e.g. SGE,
                                    AWS, SLURM, etc...). This config file is loaded last and will 
                                    overwrite existing variables if set.
                                    Default: Bactopia's default configs

        -resume                 Nextflow will attempt to resume a previous run. Please notice it is 
                                    only a single '-'

    AWS Batch Related Parameters:
        --aws_region STR        AWS Region to be used by Nextflow
                                    Default: ${params.aws_region}

        --aws_volumes STR       Volumes to be mounted from the EC2 instance to the Docker container
                                    Default: ${params.aws_volumes}

        --aws_cli_path STR       Path to the AWS CLI for Nextflow to use.
                                    Default: ${params.aws_cli_path}

        --aws_upload_storage_class STR
                                The S3 storage slass to use for storing files on S3
                                    Default: ${params.aws_upload_storage_class}

        --aws_max_parallel_transfers INT
                                The number of parallele transfers between EC2 and S3
                                    Default: ${params.aws_max_parallel_transfers}

        --aws_delay_between_attempts INT
                                The duration of sleep (in seconds) between each transfer between EC2 and S3
                                    Default: ${params.aws_delay_between_attempts}

        --aws_max_transfer_attempts INT
                                The maximum number of times to retry transferring a file between EC2 and S3
                                    Default: ${params.aws_max_transfer_attempts}

        --aws_max_retry INT     The maximum number of times to retry a process on AWS Batch
                                    Default: ${params.aws_max_retry}

        --aws_ecr_registry STR  The ECR registry containing Bactopia related containers.
                                    Default: Use the registry given by --registry 

    Useful Parameters:
        --version               Print workflow version information
        --help                  Show this message and exit
    """.stripIndent()
    exit 0
}
