def get_fastqs(wildcards):
    d=dict()
    d["R1"]=SAMPLESDF["R1"][wildcards.sample]
    d["R2"]=SAMPLESDF["R2"][wildcards.sample]
    return d

localrules: align_stats


rule trim:
    # group: "TAD"
    input:
        unpack(get_fastqs)
    output:
        R1=join(RESULTSDIR,"tmp","trim","{sample}.R1.trim.fastq.gz"),
        R2=join(RESULTSDIR,"tmp","trim","{sample}.R2.trim.fastq.gz"),
    params:
        sample="{sample}",
        scriptsdir=SCRIPTSDIR,
        script="ccbr_cutadapt_pe.bash"
    container: config["masterdocker"]    
    threads: getthreads("trim")
    shell:"""
if [ -w "/lscratch/${{SLURM_JOB_ID}}" ];then cd /lscratch/${{SLURM_JOB_ID}};else cd /dev/shm;fi
bash {params.scriptsdir}/{params.script} \
--infastq1 {input.R1} \
--infastq2 {input.R2} \
--samplename {params.sample} \
--threads {threads} \
--outfastq1 {output.R1} \
--outfastq2 {output.R2}
"""

rule remove_BL:
    # group: "TAD"
    input:
        R1=rules.trim.output.R1,
        R2=rules.trim.output.R2,
    output:
        R1=join(RESULTSDIR,"tmp","trim","{sample}.R1.noBL.fastq.gz"),
        R2=join(RESULTSDIR,"tmp","trim","{sample}.R2.noBL.fastq.gz"),
    params:
        sample="{sample}",
        scriptsdir=SCRIPTSDIR,
        genome=GENOME,
        script="ccbr_remove_blacklisted_reads_pe.bash"
    container: config["masterdocker"]    
    threads: getthreads("remove_BL")
    shell:"""
if [ -w "/lscratch/${{SLURM_JOB_ID}}" ];then cd /lscratch/${{SLURM_JOB_ID}};else cd /dev/shm;fi
bash {params.scriptsdir}/{params.script} \
--infastq1 {input.R1} \
--infastq2 {input.R2} \
--samplename {params.sample} \
--genome {params.genome} \
--threads {threads} \
--outfastq1 {output.R1} \
--outfastq2 {output.R2}
"""

rule align:
    input:
        R1=rules.remove_BL.output.R1,
        R2=rules.remove_BL.output.R2,
    output:
        tagAlign=join(RESULTSDIR,"tagAlign","{sample}.tagAlign.gz"),
        fs1=join(RESULTSDIR,"QC","{sample}.bowtie2.bam.flagstat"),
        fs2=join(RESULTSDIR,"QC","{sample}.dedup.bam.flagstat"),
        fs3=join(RESULTSDIR,"QC","{sample}.filt.bam.flagstat"),
        dupmetric=join(RESULTSDIR,"QC","{sample}.dupmetric"),
        nrf=join(RESULTSDIR,"QC","preseq","{sample}.nrf"),
    params:
        sample="{sample}",
        workdir=RESULTSDIR,
        qcdir=join(RESULTSDIR,"QC"),
        indexdir=INDEXDIR,
        scriptsdir=SCRIPTSDIR,
        genome=GENOME,
        script="ccbr_bowtie2_align_pe.bash",
        multimapping=config["multimapping"],
        mem=getmemG("align")
    container: config["masterdocker"]    
    threads: getthreads("align")
    shell:"""
if [ -w "/lscratch/${{SLURM_JOB_ID}}" ];then cd /lscratch/${{SLURM_JOB_ID}};else cd /dev/shm;fi
bash {params.scriptsdir}/{params.script} \
--infastq1 {input.R1} \
--infastq2 {input.R2} \
--samplename {params.sample} \
--genomename {params.genome} \
--threads {threads} \
--mem {params.mem} \
--indexdir {params.indexdir} \
--multimapping {params.multimapping} \
--scriptsfolder {params.scriptsdir}

rsync -az --progress {params.sample}.tagAlign.gz {params.workdir}/tagAlign/

rsync -az --progress {params.sample}.bowtie2.bam.flagstat {params.qcdir}/
rsync -az --progress {params.sample}.bowtie2.log {params.qcdir}/
rsync -az --progress {params.sample}.dedup.bam.flagstat {params.qcdir}/
rsync -az --progress {params.sample}.dupmetric {params.qcdir}/
rsync -az --progress {params.sample}.filt.bam.flagstat {params.qcdir}/

rsync -az --progress {params.sample}.nrf {params.qcdir}/preseq/
rsync -az --progress {params.sample}.preseq {params.qcdir}/preseq/
rsync -az --progress {params.sample}.preseq.log {params.qcdir}/preseq/
"""

rule align_stats:
    input:
        unpack(get_fastqs),
        trimR1=rules.trim.output.R1,
        noBLR1=rules.remove_BL.output.R1,
        fs1=rules.align.output.fs3,
        fs2=rules.align.output.fs2
    output:
        nreads=join(RESULTSDIR,"QC","{sample}.nreads.txt"),
    params:
        sample="{sample}",
    shell:"""
nreads=`zcat {input.R1}|wc -l`
nreadstrim=`zcat {input.trimR1}|wc -l`
echo "$nreads $nreadstrim"|awk '{{printf("%d\\tInput Nreads\\n%d\\tAfter trimming\\n",$1/2,$2/2)}}' > {output.nreads}
nreads=`zcat {input.noBLR1}|wc -l`
echo "$nreads"|awk '{{printf("%d\\tAfter removing mito-ribo reads\\n",$1/2)}}' >> {output.nreads}
nreads=`grep -m1 total {input.fs1}|awk '{{print $1}}'`
echo "$nreads"|awk '{{printf("%d\\tMapped reads\\n",$1)}}' >> {output.nreads}
nreads=`grep -m1 total {input.fs2}|awk '{{print $1}}'`
echo "$nreads"|awk '{{printf("%d\\tAfter deduplication\\n",$1)}}' >> {output.nreads}
"""

rule fastqc:
    input:
        expand(join(WORKDIR,"fastqs","{sample}.R1.fastq.gz"),sample=SAMPLES),
        expand(join(WORKDIR,"fastqs","{sample}.R2.fastq.gz"),sample=SAMPLES),
        expand(rules.remove_BL.output.R1,sample=SAMPLES),
        expand(rules.remove_BL.output.R2,sample=SAMPLES),
    output:
        expand(join(RESULTSDIR,"QC","fastqc","{sample}.R1_fastqc.zip"), sample=SAMPLES),
        expand(join(RESULTSDIR,"QC","fastqc","{sample}.R2_fastqc.zip"), sample=SAMPLES),
        expand(join(RESULTSDIR,"QC","fastqc","{sample}.R1.noBL_fastqc.zip"), sample=SAMPLES),
        expand(join(RESULTSDIR,"QC","fastqc","{sample}.R2.noBL_fastqc.zip"), sample=SAMPLES),
    params:
        outdir=join(RESULTSDIR,"QC","fastqc"),
    threads: getthreads("fastqc")
    container: config["masterdocker"]
    shell: """
    fastqc {input} -t {threads} -o {params.outdir};
    """      
