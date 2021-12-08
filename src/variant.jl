using BioSequences
using BioSymbols
using DataFrames

export Variant
export totaldepth
export alternatedepth

"""
    Variant

Describes a genomic mutation

The `Variant` type is based upon the
[Variant Call Format v4.2 specification](https://github.com/samtools/hts-specs#variant-calling-data-files),
albeit with imperfect compliance.

# Fields

- `chromosome::String`: An identifier from the reference genome or an angle-bracketed
    ID String
- `position::Int`: The reference position
- `identifier::String`: Semicolon-separated list of unique identifiers where available. If
    there is no identifier available, then "."" value should be used.
- `referencebase::NucleotideSeq`: Base at (or before, in case of insertion/deletion)
    `position` in the reference genome
- `alternatebase::NucleotideSeq`: Base this mutation describes at `position`. Note that
    each non-reference allele must be represented by a new `Variant`, unlike the VCF spec
- `quality::Number`: PHRED-scaled quality score for the assertion made by `alternatebase`
- `filter::Symbol`: Filter status, `:PASS` is this position has passed all filters. Does Not
    yet support multiple filters
- `info::Dict{String,Any}`: Additional information. No validation is made concerning the
    keys or values.

# Constructors

```julia
Variant(chromosome::String, position::Int, identifier::String, referencebase::NucleotideSeq,
    alternatebase::NucleotideSeq, quality::Number, filter::Symbol, info::Dict{String,Any})

Variant(data::DataFrameRow)
```

`Variant`s can be created from the default constructor, or via a row generated by
[`transformbamcounts`](@ref).

See also [`Haplotype`](@ref)

"""
struct Variant
    chromosome::String
    position::Int
    identifier::String
    referencebase::NucleotideSeq
    alternatebase::NucleotideSeq
    quality::Number
    filter::Symbol
    info::Dict{String,Any}
end #struct

function Variant(data::DataFrameRow)
    CHROM   = data.chr
    POS     = data.position
    ID      = "."
    QUAL    = data.avg_basequality
    FILTER  = :PASS
    INFO    = Dict("DP" => data.depth, "AD" => data.count)
    refbase = data.reference_base
    altbase = data.base

    # Check for insertion
    if first(altbase) == '+'
        altbase = string(refbase, altbase[2:end])
    end # if

    # Check for deletion
    if first(altbase) == '-'
        altbase = "-"
    end #if

    REF = LongDNASeq(refbase)
    ALT = LongDNASeq(altbase)

    return Variant(CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO)
end #function

function Variant(vardict::Dict{String,Any})
    region  = vardict["chromosome"]
    pos     = vardict["position"]
    id      = vardict["identifier"]
    refbase = vardict["referencebase"]
    altbase = vardict["alternatebase"]
    qual    = vardict["quality"]
    filter  = Symbol(vardict["filter"])

    refseq = LongDNASeq(refbase)
    altseq = LongDNASeq(altbase)

    return Variant(region, pos, id, refseq, altseq, qual, filter, Dict())
end #function

function Base.show(io::IO, v::Variant)
    return print(
        io,
        string(
            "Variant (",
            v.chromosome,
            ":",
            v.position,
            " ",
            v.referencebase,
            "=>",
            v.alternatebase,
            ")",
        ),
    )
end #function

function Base.isless(v1::Variant, v2::Variant)
    return v1.chromosome <= v2.chromosome && v1.position < v2.position
end #function

function varposition(v::Variant)
    return v.position
end #function

function totaldepth(v::Variant)
    return v.info["DP"]
end #function

function alternatedepth(v::Variant)
    return v.info["AD"]
end #function

"""
    serialize_yaml(v::Variant)

Create a valid YAML representation of `v`.
"""
function serialize_yaml(v::Variant)
    infostring = ""
    for n in v.info
        infostring = string(infostring, "      ", n[1], ": ", n[2], "\n")
    end #if
    return string(
        "  - chromosome: ",
        v.chromosome,
        "\n",
        "    position: ",
        string(v.position),
        "\n",
        "    identifier: ",
        string(v.identifier),
        "\n",
        "    referencebase: ",
        string(v.referencebase),
        "\n",
        "    alternatebase: ",
        string(v.alternatebase),
        "\n",
        "    quality: ",
        string(v.quality),
        "\n",
        "    filter: ",
        string(v.filter),
        "\n",
        "    info:\n",
        infostring,
    )
end #function

"""
    serialize_vcf(v::Variant)

Create a VCF line to represent `v`.
"""
function serialize_vcf(v::Variant)
    return string(
        v.chromosome,
        "\t",
        string(v.position),
        "\t",
        v.identifier,
        "\t",
        string(v.referencebase),
        "\t",
        string(v.alternatebase),
        "\t",
        string(trunc(v.quality)),
        "\t",
        string(v.filter),
        "\t",
        join([string(n[1], "=", n[2]) for n in v.info], ";"),
    )
end #function
