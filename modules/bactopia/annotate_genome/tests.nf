#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { ANNOTATE_GENOME } from './main.nf' 

workflow test_annotate_genome {

    inputs = tuple(
        "test_annotate_genome",
        false,
        [file(params.test_data['illumina']['r1'], checkIfExists: true), file(params.test_data['illumina']['r2'], checkIfExists: true)],
        file(params.test_data['reference']['fna']),
        file(params.test_data['reference']['total_contigs'])
    )

    ANNOTATE_GENOME ( inputs, file(params.test_data['empty']['proteins']), file(params.test_data['empty']['prodigal_tf']) )
}