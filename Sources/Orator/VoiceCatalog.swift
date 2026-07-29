import Foundation

struct CatalogModel: Sendable {
    let archive: String
    let engine: String
    let kind: SherpaModelKind
    let voices: [SherpaVoice]
    let needsEspeakData: Bool
    let approxSizeMB: Int
}

enum VoiceCatalog {
    static let models: [CatalogModel] = [
        CatalogModel(
            archive: "kitten-mini-en-v0_8",
            engine: "kitten",
            kind: .kitten,
            voices: [
                SherpaVoice(localID: "0", sid: 0, displayName: "Jasper (F)"),
                SherpaVoice(localID: "1", sid: 1, displayName: "Bella (F)"),
                SherpaVoice(localID: "2", sid: 2, displayName: "Bruno (M)"),
                SherpaVoice(localID: "3", sid: 3, displayName: "Luna (F)"),
                SherpaVoice(localID: "4", sid: 4, displayName: "Hugo (M)"),
                SherpaVoice(localID: "5", sid: 5, displayName: "Rosie (F)"),
                SherpaVoice(localID: "6", sid: 6, displayName: "Leo (F)"),
                SherpaVoice(localID: "7", sid: 7, displayName: "Kiki (F)"),
            ],
            needsEspeakData: true,
            approxSizeMB: 90
        ),
        piper(
            archive: "vits-piper-en_US-amy-medium",
            localID: "amy",
            displayName: "Amy (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-arctic-medium",
            localID: "arctic",
            displayName: "Arctic (M)",
            approxSizeMB: 77
        ),
        piper(
            archive: "vits-piper-en_US-bryce-medium",
            localID: "bryce",
            displayName: "Bryce (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-danny-low",
            localID: "danny",
            displayName: "Danny (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-hfc_female-medium",
            localID: "hfc_female",
            displayName: "HFC Female (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-hfc_male-medium",
            localID: "hfc_male",
            displayName: "HFC Male (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-joe-medium",
            localID: "joe",
            displayName: "Joe (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-john-medium",
            localID: "john",
            displayName: "John (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-kathleen-low",
            localID: "kathleen",
            displayName: "Kathleen (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-kristin-medium",
            localID: "kristin",
            displayName: "Kristin (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-kusal-medium",
            localID: "kusal",
            displayName: "Kusal (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-lessac-medium",
            localID: "lessac",
            displayName: "Lessac (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-ljspeech-medium",
            localID: "ljspeech",
            displayName: "LJSpeech (F)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-norman-medium",
            localID: "norman",
            displayName: "Norman (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-reza_ibrahim-medium",
            localID: "reza_ibrahim",
            displayName: "Reza (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-ryan-medium",
            localID: "ryan",
            displayName: "Ryan (M)",
            approxSizeMB: 64
        ),
        piper(
            archive: "vits-piper-en_US-sam-medium",
            localID: "sam",
            displayName: "Sam (M)",
            approxSizeMB: 64
        ),
    ]

    static func model(forVoiceID voiceID: String) -> CatalogModel? {
        guard let engine = VoiceInfo.providerID(of: voiceID) else { return nil }
        let localID = VoiceInfo.localID(of: voiceID)
        return models.first { model in
            model.engine == engine
                && model.voices.contains(where: { $0.localID == localID })
        }
    }

    static func installDir(for model: CatalogModel) -> URL {
        OratorEngine.modelsDirectory.appendingPathComponent(
            model.archive,
            isDirectory: true
        )
    }

    private static func piper(
        archive: String,
        localID: String,
        displayName: String,
        approxSizeMB: Int
    ) -> CatalogModel {
        CatalogModel(
            archive: archive,
            engine: "piper",
            kind: .vits,
            voices: [
                SherpaVoice(
                    localID: localID,
                    sid: 0,
                    displayName: displayName
                ),
            ],
            needsEspeakData: false,
            approxSizeMB: approxSizeMB
        )
    }
}
