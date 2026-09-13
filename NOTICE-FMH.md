# FMH Attribution and Distribution Notice

## Upstream Project

FMH is derived from the OpenCode project:

https://github.com/anomalyco/opencode

The upstream source code, Git history, copyright notices, contributor
attributions, and license remain applicable and are preserved in this
repository.

## FMH Additions

FMH adds and maintains the Engineering Memory System, including:

- Local hybrid project-knowledge retrieval
- First-turn knowledge integration
- Governed knowledge-candidate extraction
- Separate staging and active knowledge databases
- Mandatory human review
- Approved-only knowledge admission
- Compensating rollback after post-write verification failure
- Production memory review and admission CLI
- Retrieval abstention for unsupported queries

## Governance Boundary

FMH does not automatically approve or admit extracted knowledge.

The supported lifecycle is:

Compaction Summary
→ Candidate
→ Staging
→ Human Review
→ Approved
→ Admission
→ Future Retrieval

## License

The original OpenCode license remains preserved in the repository.

FMH additions are distributed under the repository's applicable license
unless a specific file states otherwise.
