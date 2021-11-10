module HapLink

using FASTX
using Dates
using HypothesisTests
using DataFrames
using FilePaths
using BioSequences
using BioAlignments
using BioSymbols
using Combinatorics
using Distributions
using SHA
using StructArrays
using XAM

const VERSION = "0.1.0"

export countbasestats
export callvariants
export findsimulatedhaplotypes
export findsimulatedoccurrences
export linkage

include("variant.jl")
include("haplotype.jl")

"""
    main(args::Dict{String, Any})

haplink script entry point. `args` should be generated by `ArgParse.parse_args`. See the cli
documentation for more information.
"""
function main(args::Dict{String, Any})
    # 1. Analyze bam
    # 2. Call variants
    # 3. Call haplotypes
    # 4. Export haplotypes as YAML
    # 5. Export haplotypes as FASTA

    bamfile        = args["bamfile"]
    reffile        = args["reference"]
    annotationfile = args["annotations"]
    Q_variant      = args["quality"]
    f_variant      = args["frequency"]
    x_variant      = args["position"]
    α_variant      = args["variant_significance"]
    α_haplotype    = args["haplotype_significance"]
    D_variant      = args["variant_depth"]
    D_haplotype    = args["haplotype_depth"]

    bampath = Path(bamfile)
    prefix = isnothing(args["prefix"]) ? filename(bampath) : args["prefix"]

    variants = callvariants(countbasestats(bamfile, reffile),
        Q_variant, f_variant, x_variant, α_variant, D_variant)

    iterations = 1000 # max(1000, D_haplotype*length(variants)^2)

    if !isnothing(args["variants"])
        savevcf(variants, args["variants"], reffile, D_variant, Q_variant, x_variant,α_variant)
    end #if

    if occursin("ml", args["method"])
        haplotypes = findsimulatedhaplotypes(variants, bamfile, D_haplotype, α_haplotype, iterations=iterations)
    else
        haplotypes = findhaplotypes(variants, bamfile, D_haplotype, α_haplotype)
    end #if

    @show haplotypes

end #function

"""
    countbasestats(bamfile::String, reffile::String)

Count and calculate statistics on the basecalls of the alignment in `bamfile` to the
reference genome in `reffile`. Returns a `DataFrame` with stats on every base in every
alignment position. See [`transformbamcounts`](@ref) for a complete description of the
output DataFrame schema.
"""
function countbasestats(bamfile::String, reffile::String)
    bamanalysis = ""
    open(FASTA.Reader, reffile) do refreader
        for refrecord in refreader
            chromosome = FASTA.identifier(refrecord)
            seqlength = FASTA.seqlen(refrecord)
            bamanalysis = string(
                bamanalysis,
                readchomp(`bam-readcount -f $reffile $bamfile "$chromosome:1-$seqlength"`)
            )
        end #for
    end #do
    return transformbamcounts(string.(split(bamanalysis, "\n")))
end #function

"""
    callvariants(bamcounts::AbstractDataFrame, Q_min::Int, f_min::Float64, x_min::Float64,
        α::Float64, D_min::Int)

Based on the aligned basecalls and stats in `bamcounts`, call variants and return them as a
vector of [`Variant`](@ref)s.

|         |                                                                                                |
| ------: | ---------------------------------------------------------------------------------------------- |
| `Q_min` | is the lowest average quality to allow for a variant                                           |
| `f_min` | is the lowest frequency to allow for a variant                                                 |
| `x_min` | is the highest percentage toward the edge that a call can be to be labeled a variant           |
| `α`     | is the highest ``p``-value that can be considered a significant variant by Fisher's Exact Test |
| `D_min` | is the minimum depth to call a variant                                                         |
"""
function callvariants(bamcounts::AbstractDataFrame,
    Q_min::Int, f_min::Float64, x_min::Float64, α::Float64, D_min::Int)

    variantdata = copy(bamcounts)
    filter!(var -> var.base != var.reference_base, variantdata)
    filter!(var -> var.count >= D_min, variantdata)
    filter!(var -> var.avg_basequality >= Q_min, variantdata)
    filter!(var -> var.avg_pos_as_fraction >= x_min, variantdata)
    filter!(var -> (var.count / var.depth) >= f_min, variantdata)
    filter!(
        var -> pvalue(FisherExactTest(
            round(Int, phrederror(var.avg_basequality)*var.depth),
            round(Int, (1-phrederror(var.avg_basequality))*var.depth),
            var.count,
            var.depth
        )) <= α,
        variantdata
    )
    return Variant.(eachrow(variantdata))

end #function

"""
    transformbamcounts(bamcounts::AbstractVector{String})

Convert the output from [bam-readcount](https://github.com/genome/bam-readcount) to a
`DataFrame`.

### Schema

| Column name                            | Description                                                                                                                                                                                                                                                                                   |
| -------------------------------------: | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `chr`                                  | Chromosome                                                                                                                                                                                                                                                                                    |
| `position`                             | Position                                                                                                                                                                                                                                                                                      |
| `reference_base`                       | Reference base                                                                                                                                                                                                                                                                                |
| `depth`                                | Total read depth at `position`                                                                                                                                                                                                                                                                |
| `base`                                 | Alternate base                                                                                                                                                                                                                                                                                |
| `count`                                | Number of reads containing `base` at `position`                                                                                                                                                                                                                                               |
| `avg_mapping_quality`                  | Mean mapping quality                                                                                                                                                                                                                                                                          |
| `avg_basequality`                      | Mean base quality at `position`                                                                                                                                                                                                                                                               |
| `avg_se_mapping_quality`               | Mean single-ended mapping quality                                                                                                                                                                                                                                                             |
| `num_plus_strand`                      | Number of reads on the forward strand (N/A)                                                                                                                                                                                                                                                   |
| `num_minus_strand`                     | Number of reads on the reverse strand (N/A)                                                                                                                                                                                                                                                   |
| `avg_pos_as_fraction`                  | Average position on the read as a fraction, calculated with respect to the length after clipping. This value is normalized to the center of the read: bases occurring strictly at the center of the read have a value of 1, those occurring strictly at the ends should approach a value of 0 |
| `avg_num_mismatches_as_fraction`       | Average number of mismatches on these reads per base                                                                                                                                                                                                                                          |
| `avg_sum_mismatch_qualities`           | Average sum of the base qualities of mismatches in the reads                                                                                                                                                                                                                                  |
| `num_q2_containing_reads`              | Number of reads with q2 runs at the 3’ end                                                                                                                                                                                                                                                    |
| `avg_distance_to_q2_start_in_q2_reads` | Average distance of position (as fraction of unclipped read length) to the start of the q2 run                                                                                                                                                                                                |
| `avg_clipped_length`                   | Average clipped read length                                                                                                                                                                                                                                                                   |
| `avg_distance_to_effective_3p_end`     | Average distance to the 3’ prime end of the read (as fraction of unclipped read length)                                                                                                                                                                                                       |
"""
function transformbamcounts(bamcounts::AbstractVector{String})
    # Declare an empty bam stats data frame
    countsdata = DataFrame(
        chr                                  = String[],
        position                             = Int[],
        reference_base                       = String[],
        depth                                = Int[],
        base                                 = String[],
        count                                = Int[],
        avg_mapping_quality                  = Float64[],
        avg_basequality                      = Float64[],
        avg_se_mapping_quality               = Float64[],
        num_plus_strand                      = Int[],
        num_minus_strand                     = Int[],
        avg_pos_as_fraction                  = Float64[],
        avg_num_mismatches_as_fraction       = Float64[],
        avg_sum_mismatch_qualities           = Float64[],
        num_q2_containing_reads              = Int[],
        avg_distance_to_q2_start_in_q2_reads = Float64[],
        avg_clipped_length                   = Float64[],
        avg_distance_to_effective_3p_end     = Float64[]
    )

    # Transform the bam stats file
    for bamline in bamcounts
        # Split the base-independent stats by tabs
        bamfields = split(bamline, "\t")

        # Loop through the base-dependent stat blocks
        for i in 6:length(bamfields)
                # Split the base-dependent stats by colons
                basestats = split(bamfields[i], ":")

                # Parse the data into the correct types
                chr                                  = bamfields[1]
                position                             = parse(Int, bamfields[2])
                reference_base                       = bamfields[3]
                depth                                = parse(Int, bamfields[4])
                base                                 = basestats[1]
                count                                = parse(Int, basestats[2])
                avg_mapping_quality                  = parse(Float64, basestats[3])
                avg_basequality                      = parse(Float64, basestats[4])
                avg_se_mapping_quality               = parse(Float64, basestats[5])
                num_plus_strand                      = parse(Int, basestats[6])
                num_minus_strand                     = parse(Int, basestats[7])
                avg_pos_as_fraction                  = parse(Float64, basestats[8])
                avg_num_mismatches_as_fraction       = parse(Float64, basestats[9])
                avg_sum_mismatch_qualities           = parse(Float64, basestats[10])
                num_q2_containing_reads              = parse(Int, basestats[11])
                avg_distance_to_q2_start_in_q2_reads = parse(Float64, basestats[12])
                avg_clipped_length                   = parse(Float64, basestats[13])
                avg_distance_to_effective_3p_end     = parse(Float64, basestats[14])

                # Append the data to the dataframe
                push!(countsdata, [
                    chr,
                    position,
                    reference_base,
                    depth,
                    base,
                    count,
                    avg_mapping_quality,
                    avg_basequality,
                    avg_se_mapping_quality,
                    num_plus_strand,
                    num_minus_strand,
                    avg_pos_as_fraction,
                    avg_num_mismatches_as_fraction,
                    avg_sum_mismatch_qualities,
                    num_q2_containing_reads,
                    avg_distance_to_q2_start_in_q2_reads,
                    avg_clipped_length,
                    avg_distance_to_effective_3p_end
                ])
        end #for
    end #for

    return countsdata
end #function

"""
    phrederror(quality::Number)

Converts a PHRED33-scaled error number into the expected fractional error of basecall
"""
function phrederror(qual::Number)
    return 10^(-1*qual/10)
end #function

"""
    savevcf(vars::AbstractVector{Variant}, savepatmax_varh::String, refpath::String, D::Int,
        Q::Number, x::Float64, α::Float64)

Saves the variants in `vars` to a VCF file at `savepath`, adding the reference genome
`refpath`, the depth cutoff `D`, the quality cutoff `Q`, the position cutoff `x`, and the
significance cutoff `α` as metadata.
"""
function savevcf(vars::AbstractVector{Variant}, savepath::String, refpath::String, D::Int, Q::Number, x::Float64, α::Float64)
    X = string(trunc(Int, x * 100))
    open(savepath, "w") do f
        write(f, "##fileformat=VCFv4.2\n")
        write(f, string("##filedate=", Dates.format(today(), "YYYYmmdd"), "\n"))
        write(f, string("##source=HapLink.jlv", VERSION, "\n"))
        write(f, string("##reference=file://", abspath(refpath), "\n"))
        write(f, "##FILTER=<ID=d$D,Description=\"Variant depth below $D\">\n")
        write(f, "##FILTER=<ID=q$Q,Description=\"Quality below $Q\">\n")
        write(f, "##FILTER=<ID=x$X,Description=\"Position in outer $X% of reads\">\n")
        write(f, "##FILTER=<ID=sg,Description=\"Not significant at α=$α level by Fisher's Exact Test\">\n")
        write(f, "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Read Depth\">\n")
        write(f, "##INFO=<ID=AD,Number=1,Type=Integer,Description=\"Alternate Depth\">\n")
        write(f, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n")
        for var in vars
            write(f, string(serialize_vcf(var), "\n"))
        end #for
    end #do
end #function

function findsimulatedhaplotypes(variants::AbstractVector{Variant}, bamfile::AbstractString,
    D::Int, α::Float64; iterations=1000)

    variantpairs = combinations(variants, 2)

    linkedvariantpairhaplotypes = Dict()

    for variantpair in variantpairs
        pairedhaplotype = Haplotype(variantpair)
        hapcount = findsimulatedoccurrences(pairedhaplotype, bamfile, iterations=iterations)
        if linkage(hapcount)[2] <= α && last(hapcount) >= D
            linkedvariantpairhaplotypes[pairedhaplotype] = hapcount
        end #if
    end #for

    linkedvariants = unique(cat(map(h -> h.mutations, collect(keys(linkedvariantpairhaplotypes)))..., dims=1))

    possiblelinkages = Dict()

    for variant in linkedvariants
        possiblelinkages[variant] = sort(unique(cat(map(h -> h.mutations, filter(h -> variant in h.mutations, collect(keys(linkedvariantpairhaplotypes))))..., dims=1)))
    end #for

    allvariantcombos = Haplotype.(unique(values(possiblelinkages)))

    returnedhaplotypes = Dict()

    for haplotype in allvariantcombos
        if haskey(linkedvariantpairhaplotypes, haplotype)
            returnedhaplotypes[haplotype] = linkedvariantpairhaplotypes[haplotype]
        else
            hapcount = findsimulatedoccurrences(haplotype, bamfile, iterations=iterations)
            if linkage(hapcount)[2] <= α && last(hapcount) >= D
                returnedhaplotypes[haplotype] = hapcount
            end #if
        end #if
    end #for

    return returnedhaplotypes

end #function

function findsimulatedoccurrences(haplotype::Haplotype, bamfile::AbstractString; iterations=1000)
    # Extract the SNPs we care about
    mutations = haplotype.mutations

    # Create an empty array for the simulated long reads
    pseudoreads = Array{Symbol}(undef, iterations, length(mutations))

    # Start reading the BAM file
    open(BAM.Reader, bamfile) do bamreader
        # Collect the reads
        reads = collect(bamreader)

        # Start iterating
        Threads.@threads for i ∈ 1:iterations
            # Get the reads that contain the first mutation
            lastcontainingreads = filter(b -> BAM.position(b) < mutations[1].position && BAM.rightposition(b) > mutations[1].position, reads)

            # Pull a random read from that pool
            lastread = rand(lastcontainingreads)

            # Find this read's basecall at that position
            basecall = baseatreferenceposition(lastread, mutations[1].position)
            basematch = matchvariant(basecall, mutations[1])

            pseudoreads[i, 1] = basematch

            for j ∈ 2:length(mutations)
                if (BAM.position(lastread) < mutations[j].position && BAM.rightposition(lastread) > mutations[j].position)
                    thisread = lastread
                else
                    thiscontainingreads = filter(
                        b -> BAM.position(b) > BAM.rightposition(lastread) && BAM.position(b) < mutations[j].position && BAM.rightposition(b) > mutations[j].position,
                        reads
                    )
                    if length(thiscontainingreads) < 1
                        pseudoreads[i,j] = :other
                        continue
                    end #if
                    thisread = rand(thiscontainingreads)
                end #if

                # Find this read's basecall at that position
                basecall = baseatreferenceposition(thisread, mutations[j].position)
                basematch = matchvariant(basecall, mutations[j])

                pseudoreads[i, j] = basematch

                lastread = thisread
            end #for
        end #for
    end #do

    # Set up haplotype counts
    hapcounts = zeros(Int, repeat([2], length(mutations))...)

    for i ∈ 1:iterations
        matches = pseudoreads[i, :]
        if !any(matches .== :other)
            coordinate = CartesianIndex((Int.(matches .== :alternate) .+ 1)...)
            hapcounts[coordinate] += 1
        end #if
    end #for

    return hapcounts
end #function

"""
    myref2seq(aln::Alignment, i::Int)

Replicates the functionality of BioAlignments `ref2seq`, but can handle hard clips
by effectively removing them for the intent of finding the position.
"""
function myref2seq(aln::Alignment, i::Int)
    if aln.anchors[2].op == OP_HARD_CLIP
        # Hard clipping was shown on operation 2
        # (operation 1 is always a start position)

        # Save where the clipping ends
        alnstart = aln.anchors[2]

        # Declare a new empty array where we can rebuild the alignment
        newanchors = AlignmentAnchor[]

        # Rebase the start of our new alignment to where the clipping ends
        push!(newanchors, AlignmentAnchor(
            0,
            aln.anchors[1].refpos,
            OP_START
        ))

        # Add new anchors
        for j in 3:(length(aln.anchors)-1)
            newanchor = AlignmentAnchor(
                aln.anchors[j].seqpos - alnstart.seqpos,
                aln.anchors[j].refpos,
                aln.anchors[j].op
            )
            push!(newanchors, newanchor)
        end #for

        # Package up our new alignment
        workingalignment = Alignment(newanchors)
    else
        # Package up the old alignment if there was no hard clipping
        workingalignment = aln
    end #if

    # Check that the requested base is in range
    if !seqisinrange(workingalignment, i)
        return (0, OP_HARD_CLIP)
    end

    # Perform regular alignment search, minus any hard clipping
    return ref2seq(workingalignment, i)

end #function

function seqisinrange(aln::Alignment, i::Int)
    reflen = i - first(aln.anchors).refpos
    seqlen = last(aln.anchors).seqpos - first(aln.anchors).seqpos
    return seqlen > reflen
end #function

function firstseqpos(aln::Alignment)
    return first(aln.anchors).seqpos
end #function

function lastseqpos(aln::Alignment)
    return last(aln.anchors).seqpos
end #function

"""
    matchvariant(base::Union{NucleotideSeq,DNA,AbstractVector{DNA}}, var::Variant)

Checks if `base` matches the reference or variant expected in `var`, and returns a symbol
indicating which, if any, it matches.

Returned values can be `:reference` for a reference match, `:alternate` for an alternate
match, or `:other` for no match with the given variant.
"""
function matchvariant(base::NucleotideSeq, var::Variant)
    refbase = LongDNASeq(var.referencebase)
    altbase = LongDNASeq(var.alternatebase)

    if base == refbase
        return :reference
    elseif base == altbase
        return :alternate
    else
        return :other
    end #if
end #function

function matchvariant(base::DNA, var::Variant)
    return matchvariant(LongDNASeq([base]), var)
end

function matchvariant(base::AbstractVector{DNA}, var::Variant)
    return matchvariant(LongDNASeq(base), var)
end

"""
    linkage(counts::AbstractArray{Int})

Calculates the linkage disequilibrium and Chi-squared significance level of a combination of
haplotypes whose number of occurrences are given by `counts`.

`counts` is an ``N``-dimensional array where the ``N``th dimension represents the ``N``th
variant call position within a haplotype. `findoccurrences` produces such an array.
"""
function linkage(counts::AbstractArray{Int})
    # Get the probability of finding a perfect reference sequence
    P_allref = first(counts) / sum(counts)

    # Get the probabilities of finding reference bases in any of the haplotypes
    P_refs = sumsliced.([counts], 1:ndims(counts)) ./ sum(counts)

    # Calculate linkage disequilibrium
    Δ = P_allref - prod(P_refs)

    # Calculate the test statistic
    r = Δ / (prod(P_refs .* (1 .- P_refs))^(1/ndims(counts)))
    Χ_squared = r^2 * sum(counts)

    # Calculate the significance
    p = 1 - cdf(Chisq(1), Χ_squared)

    return Δ, p
end #function

"""
    sumsliced(A::AbstractArray, dim::Int, pos::Int=1)

Sum all elements that are that can be referenced by `pos` in the `dim` dimension of `A`.

# Example

```julia-repl
julia> A = reshape(1:8, 2, 2, 2)
2×2×2 reshape(::UnitRange{Int64}, 2, 2, 2) with eltype Int64:
[:, :, 1] =
 1  3
 2  4

[:, :, 2] =
 5  7
 6  8

julia> sumsliced(A, 2)
16

julia> sumsliced(A, 2, 2)
20
```

Heavily inspired by Holy, Tim "Multidimensional algorithms and iteration"
<https://julialang.org/blog/2016/02/iteration/#filtering_along_a_specified_dimension_exploiting_multiple_indexes>
"""
function sumsliced(A::AbstractArray, dim::Int, pos::Int=1)
    i_pre  = CartesianIndices(size(A)[1:dim-1])
    i_post = CartesianIndices(size(A)[dim+1:end])
    return sum(A[i_pre, pos, i_post])
end #function

"""
    baseatreferenceposition(record::BAM.Record, pos::Int)

Get the base at reference position `pos` present in the sequence of `record`.
"""
function baseatreferenceposition(record::BAM.Record, pos::Int)
    seqpos = myref2seq(BAM.alignment(record), pos)[1]
    if seqpos > 0 && seqpos < BAM.seqlength(record)
        return BAM.sequence(record)[seqpos]
    else
        return DNA_N
    end
end # function

end #module
