import Foundation

struct ProjectNameResolver {
    struct ProjectRecord: Equatable {
        let id: String
        let name: String
    }

    enum Decision: Equatable {
        case matched(ProjectRecord)
        case ambiguous([ProjectRecord])
        case noMatch
    }

    private struct Candidate {
        let record: ProjectRecord
        let normalized: String
        let compact: String
        let tokens: [String]
    }

    func resolve(spokenName: String, projects: [ProjectRecord], maxAmbiguousResults: Int = 3) -> Decision {
        let query = Self.normalize(spokenName)
        guard !query.isEmpty else { return .noMatch }

        let queryCompact = query.replacingOccurrences(of: " ", with: "")
        let queryTokens = query.split(separator: " ").map(String.init)

        let candidates: [Candidate] = projects.compactMap { project in
            let normalized = Self.normalize(project.name)
            guard !normalized.isEmpty else { return nil }
            return Candidate(
                record: project,
                normalized: normalized,
                compact: normalized.replacingOccurrences(of: " ", with: ""),
                tokens: normalized.split(separator: " ").map(String.init)
            )
        }

        let exactMatches = candidates.filter {
            $0.normalized == query || $0.compact == queryCompact
        }
        if let decision = decisionFor(matches: exactMatches, maxAmbiguousResults: maxAmbiguousResults) {
            return decision
        }

        let strongPrefixMatches = candidates.filter {
            $0.normalized.hasPrefix(query) || $0.compact.hasPrefix(queryCompact)
        }
        if let decision = decisionFor(matches: strongPrefixMatches, maxAmbiguousResults: maxAmbiguousResults) {
            return decision
        }

        if queryTokens.count >= 2 {
            let tokenPrefixMatches = candidates.filter { candidate in
                queryTokens.allSatisfy { token in
                    candidate.tokens.contains(where: { $0.hasPrefix(token) })
                }
            }
            if let decision = decisionFor(matches: tokenPrefixMatches, maxAmbiguousResults: maxAmbiguousResults) {
                return decision
            }
        }

        if query.count >= 4 {
            let containsMatches = candidates.filter {
                $0.normalized.contains(query) || $0.compact.contains(queryCompact)
            }
            if let decision = decisionFor(matches: containsMatches, maxAmbiguousResults: maxAmbiguousResults) {
                return decision
            }
        }

        return .noMatch
    }

    private func decisionFor(matches: [Candidate], maxAmbiguousResults: Int) -> Decision? {
        guard !matches.isEmpty else { return nil }
        let unique = uniqueRecords(from: matches)
        if unique.count == 1, let only = unique.first {
            return .matched(only)
        }
        let sorted = unique.sorted {
            if $0.name.count == $1.name.count {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.name.count < $1.name.count
        }
        return .ambiguous(Array(sorted.prefix(maxAmbiguousResults)))
    }

    private func uniqueRecords(from matches: [Candidate]) -> [ProjectRecord] {
        var seen = Set<String>()
        var output: [ProjectRecord] = []
        for candidate in matches {
            if seen.insert(candidate.record.id).inserted {
                output.append(candidate.record)
            }
        }
        return output
    }

    static func normalize(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }

        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return " "
        }

        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
