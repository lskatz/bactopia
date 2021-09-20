FROM nfcore/base:1.12.1

LABEL base.image="nfcore/base:1.12.1"
LABEL software="Bactopia Tools - fastq-scan"
LABEL software.version="1.7.1"
LABEL description="Output summary read tatistics"
LABEL conda.env="bactopia/tools/fastq-scan/environment-linux.yml"
LABEL conda.md5="00000000000000000000000000000000"

COPY tools/fastq-scan/environment-linux.yml /
RUN conda env create -q -f /environment-linux.yml && conda clean -y -a
ENV PATH /opt/conda/envs/bactopia-fastq-scan/bin:$PATH
