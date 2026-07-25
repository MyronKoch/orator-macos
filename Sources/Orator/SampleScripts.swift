import Foundation

/// Bundled example scripts for the Script tab.
///
/// These exist so someone can hear a table read within seconds of opening the
/// tab, without first having to find or write a screenplay. They are held as
/// string constants rather than bundle resources deliberately: a missing
/// resource is a real shipped failure mode (see the model-file guard in
/// AppDelegate), and a few pages of text cost nothing to compile in.
///
/// All four are ORIGINAL writing, authored for this app and covered by the
/// project's MIT licence. Do not replace them with excerpts from real
/// screenplays - the app is publicly distributed and that would ship someone
/// else's copyrighted work.
///
/// Between them they exercise the whole grammar `ScriptParser` understands:
/// scene headings, action, ALL-CAPS character cues, parentheticals,
/// transitions, `(V.O.)`/`(CONT'D)` cue extensions, and both the Fountain and
/// plain `NAME:` conventions.
enum SampleScripts {

    struct Sample {
        let title: String
        /// One-line description shown in the picker: cast size and format.
        let subtitle: String
        let text: String
    }

    static let all: [Sample] = [
        theLastTransmission,
        twoSugars,
        theReadingOfTheWill,
        standupAtNineFifteen,
    ]

    // MARK: - 3 voices, Fountain

    static let theLastTransmission = Sample(
        title: "The Last Transmission",
        subtitle: "3 characters · Fountain · sci-fi",
        text: """
        INT. RELAY STATION KESTREL - NIGHT

        A room built for six, staffed by two. Frost creeps along the inside of the
        viewport. Somewhere below the floor, a pump labours and gives up.

        VERA
        Say it again. Slowly.

        COLE
        The carrier signal stopped at 04:12. Not degraded. Stopped.

        VERA
        (checking the panel herself)
        Antennas?

        COLE
        Aligned. I checked twice, then I checked a third time because I did not
        believe the first two.

        Vera puts her palm flat against the viewport. The cold reads as heat.

        VERA
        Then it isn't us.

        COLE
        No. It isn't us.

        A long pause. The pump below tries again and catches.

        NADIA (V.O.)
        Kestrel, this is Orbital. Do you copy.

        VERA
        (into the mic)
        We copy, Orbital. We had you dark for eleven minutes.

        NADIA (V.O.)
        You had us dark for eleven minutes. We had you dark for nine hours.

        Cole slowly sits down.

        COLE
        That isn't possible. We've been transmitting since midnight.

        NADIA (V.O.)
        I know what you've been doing. I've been listening to it. I just haven't
        been receiving it.

        VERA
        Orbital, say again.

        NADIA (V.O.)
        There's a delay on your signal that shouldn't exist at this distance. Nine
        hours, give or take. Whatever we're hearing from you now, you said this
        morning.

        Vera looks at Cole. Cole does not look back.

        COLE
        (quietly)
        Then she isn't talking to us.

        VERA
        She's talking to who we were.

        NADIA (V.O.)
        Kestrel? You've gone quiet again.

        Vera reaches for the mic and stops, her hand hovering.

        VERA
        Nadia. If you can hear this, and it takes nine hours to reach you - don't
        come. Whatever's out here bends more than light.

        She keys the transmitter off.

        CUT TO:

        INT. RELAY STATION KESTREL - CONTINUOUS

        The frost on the viewport has spread. It is spreading toward them.

        COLE
        How long do we have?

        VERA
        Nine hours less than we thought.
        """
    )

    // MARK: - 2 voices, NAME: convention

    static let twoSugars = Sample(
        title: "Two Sugars",
        subtitle: "2 characters · NAME: format · contemporary",
        text: """
        MAYA: You still take it with two sugars.
        DESMOND: You still notice things like that.
        MAYA: It's been six years, Des. I noticed a lot of things.
        DESMOND: You want to sit, or are we doing this standing up?
        MAYA: I want to sit. I'm just deciding whether I want to sit here.
        DESMOND: That's fair.
        MAYA: Don't do that.
        DESMOND: Do what?
        MAYA: Agree with me. It makes it very hard to have the argument I practised in the car.
        DESMOND: How long was the drive?
        MAYA: Forty minutes.
        DESMOND: And how much of it was the argument?
        MAYA: All of it. Twice.
        DESMOND: Then sit down and give me the good version.

        She sits.

        MAYA: The good version is that you were right, and I've had six years to think about how much I hate that.
        DESMOND: I wasn't right.
        MAYA: You said the company would fold inside a year.
        DESMOND: I said it might.
        MAYA: You said it at my kitchen table, with your coat on, like you were already leaving.
        DESMOND: I was already leaving. That's a different thing from being right.
        MAYA: It folded in fourteen months.
        DESMOND: Then I was wrong. I said a year.
        MAYA: Desmond.
        DESMOND: Maya.
        MAYA: I didn't drive forty minutes to litigate a timeline.
        DESMOND: No. You drove forty minutes because your sister called me, and told me you wouldn't.

        A long pause.

        MAYA: She had no right.
        DESMOND: She had every right. She's been carrying you since March and she's tired.
        MAYA: I'm handling it.
        DESMOND: I know. That's what worries the people who love you. You handle everything. You just don't put any of it down.
        MAYA: Is that why you came?
        DESMOND: I came because you asked for coffee, and because in six years you've never once asked me for anything. I wasn't going to be busy for that.
        MAYA: It's just coffee.
        DESMOND: It's never just coffee. You take yours black, and you ordered two sugars, and you've been stirring it since I sat down.

        She stops stirring.

        MAYA: Okay.
        DESMOND: Okay.
        MAYA: Can we start again? Properly.
        DESMOND: Hi, Maya.
        MAYA: Hi.
        """
    )

    // MARK: - 4 voices, Fountain with transitions

    static let theReadingOfTheWill = Sample(
        title: "The Reading of the Will",
        subtitle: "4 characters · Fountain · period drama",
        text: """
        INT. ASHCROFT & SON, SOLICITORS - READING ROOM - DAY

        Rain against tall windows. A table too large for the four people seated at
        it. MR. ASHCROFT unties a ribbon from a folder with great ceremony.

        MR. ASHCROFT
        Before I begin, I am obliged to say that your father was of sound mind when
        this was drawn, and that he was aware of precisely how it would be received.

        EDWIN
        Meaning he enjoyed it.

        MR. ASHCROFT
        Meaning he was aware.

        CLARA
        Let him read it, Edwin.

        MR. ASHCROFT
        (reading)
        "To my son Edwin, who has never once asked me for advice and has therefore
        never once been refused it, I leave the house at Colworth."

        Edwin sits back, satisfied.

        MR. ASHCROFT (CONT'D)
        "And the debts secured against it."

        The satisfaction leaves Edwin's face by degrees.

        EDWIN
        The what?

        MR. ASHCROFT
        There are four. I have the schedule, if you would like it now or in a moment
        when you are seated more firmly.

        MRS. POOLE
        In a moment, I should think.

        MR. ASHCROFT
        (reading)
        "To my daughter Clara, who asked for nothing and was given rather less, I
        leave the whole of the Cheapside holdings, the annuity, and my apology,
        which she may keep or return as she sees fit."

        Silence. Clara does not move.

        CLARA
        He wrote that down.

        MR. ASHCROFT
        He dictated it. Twice. He was dissatisfied with the first attempt.

        EDWIN
        This is absurd. She hasn't been to the house in nine years.

        CLARA
        Eleven.

        EDWIN
        Eleven, then. Eleven years and she takes Cheapside?

        MRS. POOLE
        She takes Cheapside because she was not there, Edwin. That is rather the
        point, and you have just made it for him.

        Edwin turns on her.

        EDWIN
        And what does the housekeeper get?

        MR. ASHCROFT
        (turning the page)
        "To Mrs. Poole, who ran my house for thirty-one years and corrected me on
        every occasion I deserved it, I leave two thousand pounds and the small
        painting in the morning room, which she has admired since 1889 and has never
        once mentioned."

        Mrs. Poole's composure does not break. It simply relocates.

        MRS. POOLE
        He noticed that.

        MR. ASHCROFT
        He noticed a great deal. He said very little. I found it a trying
        combination in a client and an admirable one in a man.

        CLARA
        Is there more?

        MR. ASHCROFT
        One line.
        (reading)
        "I have divided this as fairly as I know how, which is not the same as
        equally, and I expect to be misunderstood."

        He sets the page down.

        MR. ASHCROFT (CONT'D)
        He was, I think, correct on both counts.

        > FADE OUT
        """
    )

    // MARK: - 3 voices, numbers and jargon

    static let standupAtNineFifteen = Sample(
        title: "Standup at 9:15",
        subtitle: "3 characters · NAME: format · workplace comedy",
        text: """
        INT. OPEN-PLAN OFFICE - MORNING

        Three people stand in a loose triangle. Nobody wants to go first.

        PRIYA: Right. Standup. Ninety seconds each, and I mean it this time.
        TOMAS: You said that yesterday and we went for 35 minutes.
        PRIYA: Yesterday was an outlier.
        BEN: Yesterday was Tuesday. We've gone over on 14 of the last 15 Tuesdays.
        PRIYA: Ben.
        BEN: I have a spreadsheet.
        PRIYA: I know you have a spreadsheet. Everyone knows you have a spreadsheet. Tomas, go.
        TOMAS: Yesterday I closed out the caching work. Response times went from 1,240 milliseconds down to about 90.
        BEN: 90?
        TOMAS: Give or take.
        BEN: That's a 93 percent improvement.
        TOMAS: If you say so.
        BEN: I do say so. I said so at 11:40 last night when the dashboard turned green and I assumed it was broken.
        PRIYA: And today?
        TOMAS: Today I find out why it works, because right now I genuinely don't know.
        PRIYA: That's not a blocker, that's a mystery.
        TOMAS: It's a mystery that's currently in production.
        PRIYA: Then it's a blocker. Ben.
        BEN: I'm on the export bug. The one where the file comes out empty.
        PRIYA: The 3rd time we've fixed that.
        BEN: The 4th. And I found it. We were finalising the container after we reported success, so anything that opened the file immediately got an unfinished header.
        TOMAS: How long was the gap?
        BEN: About 40 milliseconds.
        TOMAS: 40 milliseconds.
        BEN: Enough. It was always enough. It just needed someone fast enough to notice.
        PRIYA: Ship it today?
        BEN: Ship it today.
        PRIYA: Good. Mine's short. The board moved the review from the 22nd to the 16th.
        TOMAS: That's six days.
        PRIYA: That's six days.
        BEN: Do they know it's six days?
        PRIYA: They know it's the 16th. Whether they've done the subtraction is above my pay grade.
        TOMAS: So what comes out?
        PRIYA: Nothing comes out. We were always going to be ready on the 16th, we just didn't know it until this morning.
        BEN: That's the most terrifying sentence you've ever said in this room.
        PRIYA: Ninety seconds. We came in at 88.
        TOMAS: That's because nobody asked how I was.
        PRIYA: How are you, Tomas?
        TOMAS: Deeply unwell. The caching works and I don't know why.
        PRIYA: Standup's over.
        """
    )
}
