using BioSequences
using BioSymbols
using DataFrames

"""
    Variant(chromosome::String, position::Int, identifier::String,
        referencebase::NucleotideSeq, alternatebase::NucleotideSeq, quality::Number,
        filter::Symbol, info::Dict{String,Any})

Create a new `Variant` record. All fields correspond to the Variant Call Format
specification.
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

"""
    Variant(data::DataFrameRow)

Creates a [`Variant`](@ref) object from a row generated by [`transformbamcounts`](@ref).
"""
function Variant(data::DataFrameRow)
    CHROM  = data.chr
    POS    = data.position
    ID     = "."
    QUAL   = data.avg_basequality
    FILTER = :PASS
    INFO   = Dict(
        "DP" => data.depth,
        "AD" => data.count
    )
    refbase    = data.reference_base
    altbase    = data.base

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

function Base.isless(v1::Variant, v2::Variant)
    return v1.chromosome < v2.chromosome && v1.position < v2.position
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
        infostring
    )
end #function

"""
    serialize_vcf(v::Variant)

Create a VCF line to represent `v`.
"""
function serialize_vcf(v::Variant)
    return string(
        v.chromosome,             "\t",
        string(v.position),       "\t",
        v.identifier,             "\t",
        string(v.referencebase),  "\t",
        string(v.alternatebase),  "\t",
        string(trunc(v.quality)), "\t",
        string(v.filter),         "\t",
        join([string(n[1],"=",n[2]) for n in v.info], ";")
    )
end #function