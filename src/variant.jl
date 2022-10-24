function SequenceVariation.Variant(
    query::Union{SAM.Record,BAM.Record}, reference::NucleotideSeq
)
    XAM = typeof(query) == SAM.Record ? SAM : BAM

    aligned_seq = AlignedSequence(XAM.sequence(query), XAM.alignment(query))
    paired_alignment = PairwiseAlignment(aligned_seq, reference)

    return Variant(paired_alignment)
end #function
