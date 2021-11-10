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
export sumsliced

include("variant.jl")
include("haplotype.jl")
include("readcounts.jl")
include("sequences.jl")

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

    # Read the argument table in as variables
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

    # Find the file prefix for output files if none was provided
    bampath = Path(bamfile)
    prefix = isnothing(args["prefix"]) ? filename(bampath) : args["prefix"]

    # Call variants
    variants = callvariants(
        countbasestats(bamfile, reffile),
        D_variant,
        Q_variant,
        x_variant,
        f_variant,
        α_variant
    )


    # Save the variants to a VCF file, if requested
    if !isnothing(args["variants"])
        savevcf(
            variants,
            args["variants"],
            reffile,
            D_variant,
            Q_variant,
            x_variant,
            α_variant
        )
    end #if



    if occursin("ml", args["method"])
        # TODO: implement an expression-evaluator for ML iterations
        # Calculate the number of iterations for each haplotype
        iterations = 1000 # max(1000, D_haplotype*length(variants)^2)

        haplotypes = findsimulatedhaplotypes(
            variants,
            bamfile,
            D_haplotype,
            α_haplotype,
            iterations=iterations
        )
    else
        haplotypes = findhaplotypes(variants, bamfile, D_haplotype, α_haplotype)
    end #if

    println(serialize_yaml.(collect(keys(haplotypes)))...)

end #function

"""
    callvariants(bamcounts::AbstractDataFrame, D_min::Int, Q_min::Int, x_min::Float64,
        f_min::Float64, α::Float64)

Based on the aligned basecalls and stats in `bamcounts`, call variants.

# Arguments
- `bamcounts::AbstractDataFrame`: `DataFrame` containing the output from `bam-readcount`
- `D_min::Int`: minimum variant depth
- `Q_min::Int`: minimum average PHRED-scaled quality at variant position
- `x_min::Float64`: minimum average fractional distance from read end at variant position
- `f_min::Float64`: minimum frequency of variant
- `α::Float64`: significance level of variants by Fisher's Exact Test

# Returns
- `Vector{Variant}`: [`Variant`](@ref)s that passed all the above filters
"""
function callvariants(
    bamcounts::AbstractDataFrame,
    D_min::Int,
    Q_min::Int,
    x_min::Float64,
    f_min::Float64,
    α::Float64
)

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
    phrederror(quality::Number)

Converts a PHRED33-scaled error number into the expected fractional error of basecall
"""
function phrederror(qual::Number)
    return 10^(-1*qual/10)
end #function

"""
    savevcf(vars::AbstractVector{Variant}, savepath::String, refpath::String, D::Int,
        Q::Number, x::Float64, α::Float64)

Save a VCF file populated with `vars`

# Arguments
- `vars::AbstractVector{Variant}`: `Vector` of [`Variant`](@ref)s to write to file
- `savepath::AbstractString`: path of the VCF file to write to. Will be overwritten
- `refpath::AbstractString`: path of the reference genome used to call variants. The
    absolute path will be added to the `##reference` metadata
- `D::Int`: mimimum variant depth used to filter variants. Will be added as `##FILTER`
    metadata
- `Q::Number`: minimum PHRED quality used to filter variants. Will be added as `##FILTER`
    metadata
- `x::Float64`: minimum fractional read position used to filter variants. Will be added as
    `##FILTER` metadata
- `α::Float64`: Fisher's Exact Test significance level used to filter variants. Will be
    added as `##FILTER` metadata

Saves the variants in `vars` to a VCF file at `savepath`, adding the reference genome
`refpath`, the depth cutoff `D`, the quality cutoff `Q`, the position cutoff `x`, and the
significance cutoff `α` as metadata.
"""
function savevcf(
    vars::AbstractVector{Variant},
    savepath::AbstractString,
    refpath::AbstractString,
    D::Int,
    Q::Number,
    x::Float64,
    α::Float64
)

    # Convert read position to integer percent
    X = string(trunc(Int, x * 100))

    # Open the file via clobbering
    open(savepath, "w") do f
        # Write headers
        write(f, "##fileformat=VCFv4.2\n")
        write(f, string("##filedate=", Dates.format(today(), "YYYYmmdd"), "\n"))
        write(f, string("##source=HapLink.jlv", VERSION, "\n"))
        write(f, string("##reference=file://", abspath(refpath), "\n"))

        # Write filter metadata
        write(f, "##FILTER=<ID=d$D,Description=\"Variant depth below $D\">\n")
        write(f, "##FILTER=<ID=q$Q,Description=\"Quality below $Q\">\n")
        write(f, "##FILTER=<ID=x$X,Description=\"Position in outer $X% of reads\">\n")
        write(f, "##FILTER=<ID=sg,Description=\"Not significant at α=$α level by Fisher's Exact Test\">\n")

        # Add descriptions of the info tags I chose to include
        # TODO: Find a way for these _not_ to be hard-coded in here
        write(f, "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Read Depth\">\n")
        write(f, "##INFO=<ID=AD,Number=1,Type=Integer,Description=\"Alternate Depth\">\n")

        # Write the header line?
        # TODO: Check this header against VCF spec
        write(f, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n")

        # Write every variant out
        for var in vars
            write(f, string(serialize_vcf(var), "\n"))
        end #for
    end #do
end #function

function findsimulatedhaplotypes(
    variants::AbstractVector{Variant},
    bamfile::AbstractString,
    D::Int,
    α::Float64;
    iterations=1000
)

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

function findsimulatedoccurrences(
    haplotype::Haplotype,
    bamfile::AbstractString;
    iterations=1000
)

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
            lastcontainingreads = filter(
                b -> BAM.position(b) < mutations[1].position && BAM.rightposition(b) > mutations[1].position,
                reads
            )

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

```jldoctest
julia> A = reshape(1:8, 2, 2, 2)
2×2×2 reshape(::UnitRange{Int64}, 2, 2, 2) with eltype Int64:
[:, :, 1] =
 1  3
 2  4

[:, :, 2] =
 5  7
 6  8

julia> sumsliced(A, 2)
14

julia> sumsliced(A, 2, 2)
22
```

Heavily inspired by Holy, Tim "Multidimensional algorithms and iteration"
<https://julialang.org/blog/2016/02/iteration/#filtering_along_a_specified_dimension_exploiting_multiple_indexes>
"""
function sumsliced(A::AbstractArray, dim::Int, pos::Int=1)
    i_pre  = CartesianIndices(size(A)[1:dim-1])
    i_post = CartesianIndices(size(A)[dim+1:end])
    return sum(A[i_pre, pos, i_post])
end #function

end #module
