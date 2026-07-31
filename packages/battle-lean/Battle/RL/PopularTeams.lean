/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.RL.GeneratorSafe

/-!
# Popular Generation-I competitive teams

Derived from every Generation-I parquet split in
`HolidayOugi/pokemon-showdown-replays` at revision
`bc76388c2119f8a5694adf643c640610b157ee1c` (last modified 2026-06-20).

A team observation requires a declared team size of six, six unique canonical
species revealed by team preview or switch/drag/replace events, and default
level 100 or explicit level 100. Hidden, incomplete, lower-level, and
noncanonical rosters are excluded. Team order is canonicalized because old
replays do not reveal hidden party positions. The 200 most frequent exact
compositions come from 149,558 eligible observations and 24,870 unique teams.

Moves are reconstructed from all battle sides sharing an exact composition.
Each move contributes at most once per species per battle, avoiding usage-count
bias from repeatedly selected attacks. Called Metronome/Mirror Move results,
Mimic copies, transformed moves, and Struggle are excluded. The four
most-frequently observed canonical moves are retained per species. One set with
only three canonical observations is completed from that species' aggregate
across all top-200 team matches. Only aggregate teams, moves, and counts remain;
player names and logs are omitted.
-/

namespace Battle.RL.PopularTeams

structure Set where
  species : SpeciesId
  moves : Array MoveId
  deriving Repr, BEq, Inhabited

structure Entry where
  usage : Nat
  sets : Array Set
  deriving Repr, BEq, Inhabited

/-- Readable aliases for the cartridge-internal IDs retained by this generated
table. The `s` prefix identifies species and `m` identifies moves. -/
private abbrev sRhydon : SpeciesId := 0x01
private abbrev sKangaskhan : SpeciesId := 0x02
private abbrev sNidoking : SpeciesId := 0x07
private abbrev sSlowbro : SpeciesId := 0x08
private abbrev sExeggutor : SpeciesId := 0x0a
private abbrev sGengar : SpeciesId := 0x0e
private abbrev sNidoqueen : SpeciesId := 0x10
private abbrev sLapras : SpeciesId := 0x13
private abbrev sArcanine : SpeciesId := 0x14
private abbrev sMew : SpeciesId := 0x15
private abbrev sGyarados : SpeciesId := 0x16
private abbrev sTentacool : SpeciesId := 0x18
private abbrev sGastly : SpeciesId := 0x19
private abbrev sScyther : SpeciesId := 0x1a
private abbrev sStaryu : SpeciesId := 0x1b
private abbrev sBlastoise : SpeciesId := 0x1c
private abbrev sPinsir : SpeciesId := 0x1d
private abbrev sFearow : SpeciesId := 0x23
private abbrev sKadabra : SpeciesId := 0x26
private abbrev sChansey : SpeciesId := 0x28
private abbrev sMrMime : SpeciesId := 0x2a
private abbrev sParasect : SpeciesId := 0x2e
private abbrev sGolem : SpeciesId := 0x31
private abbrev sMagmar : SpeciesId := 0x33
private abbrev sTauros : SpeciesId := 0x3c
private abbrev sDragonite : SpeciesId := 0x42
private abbrev sJynx : SpeciesId := 0x48
private abbrev sMoltres : SpeciesId := 0x49
private abbrev sArticuno : SpeciesId := 0x4a
private abbrev sZapdos : SpeciesId := 0x4b
private abbrev sPikachu : SpeciesId := 0x54
private abbrev sRaichu : SpeciesId := 0x55
private abbrev sKabutops : SpeciesId := 0x5b
private abbrev sSandslash : SpeciesId := 0x61
private abbrev sWigglytuff : SpeciesId := 0x65
private abbrev sFlareon : SpeciesId := 0x67
private abbrev sJolteon : SpeciesId := 0x68
private abbrev sVaporeon : SpeciesId := 0x69
private abbrev sPoliwrath : SpeciesId := 0x6f
private abbrev sBeedrill : SpeciesId := 0x72
private abbrev sDodrio : SpeciesId := 0x74
private abbrev sPrimeape : SpeciesId := 0x75
private abbrev sDugtrio : SpeciesId := 0x76
private abbrev sVenomoth : SpeciesId := 0x77
private abbrev sButterfree : SpeciesId := 0x7d
private abbrev sHypno : SpeciesId := 0x81
private abbrev sGolbat : SpeciesId := 0x82
private abbrev sMewtwo : SpeciesId := 0x83
private abbrev sSnorlax : SpeciesId := 0x84
private abbrev sKingler : SpeciesId := 0x8a
private abbrev sCloyster : SpeciesId := 0x8b
private abbrev sElectrode : SpeciesId := 0x8d
private abbrev sClefable : SpeciesId := 0x8e
private abbrev sPersian : SpeciesId := 0x90
private abbrev sAlakazam : SpeciesId := 0x95
private abbrev sPidgeot : SpeciesId := 0x97
private abbrev sStarmie : SpeciesId := 0x98
private abbrev sVenusaur : SpeciesId := 0x9a
private abbrev sTentacruel : SpeciesId := 0x9b
private abbrev sSeaking : SpeciesId := 0x9e
private abbrev sRaticate : SpeciesId := 0xa6
private abbrev sCharizard : SpeciesId := 0xb4
private abbrev sVictreebel : SpeciesId := 0xbe

private abbrev mSwordsDance : MoveId := 14
private abbrev mStomp : MoveId := 23
private abbrev mDoubleKick : MoveId := 24
private abbrev mMegaKick : MoveId := 25
private abbrev mBodySlam : MoveId := 34
private abbrev mWrap : MoveId := 35
private abbrev mDoubleEdge : MoveId := 38
private abbrev mTailWhip : MoveId := 39
private abbrev mTwineedle : MoveId := 41
private abbrev mPinMissile : MoveId := 42
private abbrev mGrowl : MoveId := 45
private abbrev mSing : MoveId := 47
private abbrev mFlamethrower : MoveId := 53
private abbrev mHydroPump : MoveId := 56
private abbrev mSurf : MoveId := 57
private abbrev mIceBeam : MoveId := 58
private abbrev mBlizzard : MoveId := 59
private abbrev mBubbleBeam : MoveId := 61
private abbrev mHyperBeam : MoveId := 63
private abbrev mDrillPeck : MoveId := 65
private abbrev mSubmission : MoveId := 66
private abbrev mCounter : MoveId := 68
private abbrev mSeismicToss : MoveId := 69
private abbrev mStrength : MoveId := 70
private abbrev mMegaDrain : MoveId := 72
private abbrev mLeechSeed : MoveId := 73
private abbrev mRazorLeaf : MoveId := 75
private abbrev mStunSpore : MoveId := 78
private abbrev mSleepPowder : MoveId := 79
private abbrev mFireSpin : MoveId := 83
private abbrev mThunderbolt : MoveId := 85
private abbrev mThunderWave : MoveId := 86
private abbrev mThunder : MoveId := 87
private abbrev mEarthquake : MoveId := 89
private abbrev mToxic : MoveId := 92
private abbrev mPsychic : MoveId := 94
private abbrev mHypnosis : MoveId := 95
private abbrev mAgility : MoveId := 97
private abbrev mQuickAttack : MoveId := 98
private abbrev mNightShade : MoveId := 101
private abbrev mMimic : MoveId := 102
private abbrev mScreech : MoveId := 103
private abbrev mRecover : MoveId := 105
private abbrev mConfuseRay : MoveId := 109
private abbrev mDefenseCurl : MoveId := 111
private abbrev mLightScreen : MoveId := 113
private abbrev mReflect : MoveId := 115
private abbrev mSelfDestruct : MoveId := 120
private abbrev mEggBomb : MoveId := 121
private abbrev mFireBlast : MoveId := 126
private abbrev mClamp : MoveId := 128
private abbrev mAmnesia : MoveId := 133
private abbrev mSoftBoiled : MoveId := 135
private abbrev mLeechLife : MoveId := 141
private abbrev mLovelyKiss : MoveId := 142
private abbrev mTransform : MoveId := 144
private abbrev mSpore : MoveId := 147
private abbrev mCrabhammer : MoveId := 152
private abbrev mExplosion : MoveId := 153
private abbrev mRest : MoveId := 156
private abbrev mRockSlide : MoveId := 157
private abbrev mTriAttack : MoveId := 161
private abbrev mSuperFang : MoveId := 162
private abbrev mSlash : MoveId := 163
private abbrev mSubstitute : MoveId := 164

/-- Top 200 exact teams, descending by observed composition usage. -/
def teams : Array Entry := #[
  { usage := 9286,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 8523,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 4363,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 3859,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 3078,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mSurf] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 2915,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mSeismicToss, mPsychic, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mSing, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 2868,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1906,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 1707,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1560,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1397,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mSeismicToss, mIceBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1255,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 1204,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mRest, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1096,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 1070,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 961,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 952,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 940,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 825,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSing, mSoftBoiled, mIceBeam, mThunderWave] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 822,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 807,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSing, mSoftBoiled, mIceBeam, mThunderWave] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 777,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 707,
    sets := #[
      { species := sChansey, moves := #[mSing, mIceBeam, mSoftBoiled, mThunderWave] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 660,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 618,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 608,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 599,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mSing, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 582,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mNightShade, mPsychic] },
      { species := sJolteon, moves := #[mThunderbolt, mDoubleKick, mThunderWave, mPinMissile] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 576,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 479,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderbolt, mThunderWave] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mRest] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mReflect, mRest, mBodySlam, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 474,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSing] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mPsychic, mRecover] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 437,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mIceBeam] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mWrap, mRazorLeaf, mSleepPowder, mStunSpore] }
    ] },
  { usage := 414,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSing] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sGengar, moves := #[mHypnosis, mThunderbolt, mExplosion, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mHyperBeam, mReflect, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 408,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sArticuno, moves := #[mIceBeam, mBlizzard, mAgility, mHyperBeam] },
      { species := sCloyster, moves := #[mExplosion, mBlizzard, mClamp, mHyperBeam] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mSubstitute] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mThunderbolt, mEarthquake] }
    ] },
  { usage := 395,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 389,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mSing, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mHyperBeam] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mBodySlam, mRockSlide] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 385,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mAmnesia, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 382,
    sets := #[
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 378,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 371,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mHyperBeam] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mSing, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderWave, mThunderbolt, mAgility] }
    ] },
  { usage := 347,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sMew, moves := #[mSwordsDance, mSoftBoiled, mEarthquake, mBodySlam] },
      { species := sMewtwo, moves := #[mAmnesia, mRecover, mIceBeam, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mStomp] }
    ] },
  { usage := 344,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mSing, mIceBeam, mThunderWave] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 331,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mBodySlam, mConfuseRay] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 331,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 313,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] }
    ] },
  { usage := 292,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mAgility, mDoubleEdge, mHyperBeam] },
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mSing, mCounter] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mThunderbolt] },
      { species := sZapdos, moves := #[mThunderbolt, mThunderWave, mDrillPeck, mAgility] }
    ] },
  { usage := 292,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 289,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sPersian, moves := #[mSlash, mHyperBeam, mBubbleBeam, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 287,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 287,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mSleepPowder] },
      { species := sGengar, moves := #[mExplosion, mPsychic, mHypnosis, mThunderbolt] },
      { species := sJynx, moves := #[mBlizzard, mLovelyKiss, mPsychic, mBodySlam] },
      { species := sPersian, moves := #[mSlash, mBodySlam, mBubbleBeam, mGrowl] },
      { species := sSnorlax, moves := #[mSelfDestruct, mBodySlam, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 284,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mSing, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 284,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mThunderbolt, mIceBeam] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mCounter] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mReflect] },
      { species := sStarmie, moves := #[mSurf, mThunderbolt, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 274,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mThunderWave, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 274,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mRest, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 267,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mBodySlam, mConfuseRay] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 264,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 260,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mThunderWave, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 249,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mSing] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mStunSpore, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] }
    ] },
  { usage := 247,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mSing, mIceBeam] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mThunderbolt, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 243,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sPersian, moves := #[mSlash, mHyperBeam, mBubbleBeam, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 238,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mCounter, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 232,
    sets := #[
      { species := sChansey, moves := #[mSing, mSoftBoiled, mIceBeam, mThunderWave] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 223,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mReflect, mAgility] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 216,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mIceBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] }
    ] },
  { usage := 214,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mSing, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mHyperBeam] },
      { species := sGengar, moves := #[mHypnosis, mPsychic, mThunderbolt, mExplosion] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 214,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mThunderbolt, mExplosion, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 213,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mLightScreen, mThunderWave, mSoftBoiled] },
      { species := sJynx, moves := #[mBlizzard, mLovelyKiss, mSeismicToss, mPsychic] },
      { species := sMew, moves := #[mExplosion, mSwordsDance, mBodySlam, mEarthquake] },
      { species := sMewtwo, moves := #[mIceBeam, mAmnesia, mThunderbolt, mRecover] },
      { species := sSlowbro, moves := #[mSurf, mThunderWave, mAmnesia, mRest] },
      { species := sSnorlax, moves := #[mSelfDestruct, mHyperBeam, mBodySlam, mEarthquake] }
    ] },
  { usage := 210,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mSing] },
      { species := sExeggutor, moves := #[mPsychic, mStunSpore, mSleepPowder, mExplosion] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mPsychic] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mThunderbolt, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 210,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mThunderbolt, mNightShade] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mHyperBeam, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 206,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mReflect] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 202,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mHyperBeam] },
      { species := sCharizard, moves := #[mFireBlast, mSwordsDance, mEarthquake, mHyperBeam] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mStunSpore, mExplosion] },
      { species := sGengar, moves := #[mConfuseRay, mThunderbolt, mPsychic, mHypnosis] },
      { species := sSnorlax, moves := #[mAmnesia, mBodySlam, mReflect, mIceBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 201,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mReflect] },
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mCounter] },
      { species := sExeggutor, moves := #[mSleepPowder, mExplosion, mMegaDrain, mPsychic] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mBodySlam, mSubstitute] },
      { species := sStarmie, moves := #[mThunderbolt, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mHyperBeam, mBodySlam, mBlizzard, mEarthquake] }
    ] },
  { usage := 199,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sStarmie, moves := #[mThunderWave, mThunderbolt, mBlizzard, mRecover] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 198,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mSing, mSeismicToss, mIceBeam] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 198,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 198,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mSleepPowder] },
      { species := sGengar, moves := #[mExplosion, mThunderbolt, mHypnosis, mPsychic] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 196,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mSing, mThunderWave] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 192,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 188,
    sets := #[
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sMew, moves := #[mSwordsDance, mBodySlam, mSoftBoiled, mReflect] },
      { species := sMewtwo, moves := #[mAmnesia, mIceBeam, mPsychic, mRecover] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mIceBeam, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 187,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mCounter] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 184,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mLightScreen] },
      { species := sExeggutor, moves := #[mPsychic, mStunSpore, mExplosion, mSleepPowder] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sMew, moves := #[mSwordsDance, mEarthquake, mSoftBoiled, mBodySlam] },
      { species := sMewtwo, moves := #[mAmnesia, mRecover, mIceBeam, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mCounter, mEarthquake] }
    ] },
  { usage := 183,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mReflect, mThunderWave, mSoftBoiled, mSeismicToss] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mAmnesia, mReflect, mRest, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mToxic] }
    ] },
  { usage := 179,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mMegaDrain] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mThunderbolt, mPsychic] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mRest, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mThunderWave, mDrillPeck, mAgility] }
    ] },
  { usage := 178,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sCloyster, moves := #[mBlizzard, mExplosion, mClamp, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderWave, mDrillPeck, mThunderbolt, mAgility] }
    ] },
  { usage := 175,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sMew, moves := #[mSwordsDance, mEarthquake, mSoftBoiled, mExplosion] },
      { species := sMewtwo, moves := #[mAmnesia, mPsychic, mRecover, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sZapdos, moves := #[mThunderWave, mThunderbolt, mDrillPeck, mAgility] }
    ] },
  { usage := 171,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mPinMissile, mDoubleKick] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mRest, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 169,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSeismicToss, mSoftBoiled, mSing] },
      { species := sExeggutor, moves := #[mPsychic, mLeechSeed, mStunSpore, mSleepPowder] },
      { species := sLapras, moves := #[mBlizzard, mConfuseRay, mThunderbolt, mBodySlam] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 169,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mSleepPowder] },
      { species := sHypno, moves := #[mPsychic, mThunderWave, mHypnosis, mSubmission] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mSubmission] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mRest, mReflect] },
      { species := sStarmie, moves := #[mThunderWave, mThunderbolt, mBlizzard, mRecover] }
    ] },
  { usage := 169,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mSelfDestruct, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 162,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 160,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 156,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sCloyster, moves := #[mBlizzard, mExplosion, mSurf, mClamp] },
      { species := sExeggutor, moves := #[mSleepPowder, mLeechSeed, mPsychic, mExplosion] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mThunderWave, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 155,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mThunderbolt, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 154,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mSleepPowder, mWrap, mRazorLeaf, mSwordsDance] }
    ] },
  { usage := 154,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 149,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderbolt, mThunderWave] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mRockSlide, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mBlizzard, mHyperBeam, mEarthquake] }
    ] },
  { usage := 149,
    sets := #[
      { species := sCharizard, moves := #[mSlash, mBodySlam, mFireBlast, mEarthquake] },
      { species := sKabutops, moves := #[mSlash, mSurf, mBodySlam, mSwordsDance] },
      { species := sMrMime, moves := #[mPsychic, mThunderWave, mSeismicToss, mThunderbolt] },
      { species := sNidoking, moves := #[mEarthquake, mThunderbolt, mBlizzard, mSubstitute] },
      { species := sRaticate, moves := #[mBodySlam, mHyperBeam, mThunderbolt, mSuperFang] },
      { species := sVenomoth, moves := #[mSleepPowder, mPsychic, mStunSpore, mDoubleEdge] }
    ] },
  { usage := 147,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mIceBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mMegaDrain] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 144,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSeismicToss, mSoftBoiled, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 142,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sMoltres, moves := #[mFireBlast, mFireSpin, mAgility, mHyperBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mReflect, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 142,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mAmnesia, mRest, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 141,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mReflect] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mStunSpore, mExplosion] },
      { species := sPinsir, moves := #[mSwordsDance, mHyperBeam, mSubmission, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mBlizzard, mPsychic, mRecover, mThunderWave] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 141,
    sets := #[
      { species := sChansey, moves := #[mSeismicToss, mLightScreen, mThunderWave, mSoftBoiled] },
      { species := sExeggutor, moves := #[mExplosion, mPsychic, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mSeismicToss, mRest] },
      { species := sMew, moves := #[mTransform, mReflect, mThunderWave, mSoftBoiled] },
      { species := sMewtwo, moves := #[mAmnesia, mIceBeam, mPsychic, mRecover] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mThunderWave, mRest] }
    ] },
  { usage := 133,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mRest, mThunderWave] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 131,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mAgility, mIceBeam, mHyperBeam] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mThunderWave, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 131,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mReflect, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mSurf, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 130,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sBlastoise, moves := #[mCounter, mSurf, mBlizzard, mEarthquake] },
      { species := sChansey, moves := #[mBlizzard, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sCharizard, moves := #[mFlamethrower, mSlash, mCounter, mEarthquake] },
      { species := sRaichu, moves := #[mThunderbolt, mThunderWave, mBodySlam, mSubmission] },
      { species := sVenusaur, moves := #[mSleepPowder, mRazorLeaf, mLeechSeed, mBodySlam] }
    ] },
  { usage := 129,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sKingler, moves := #[mSwordsDance, mHyperBeam, mCrabhammer, mBodySlam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mLightScreen] }
    ] },
  { usage := 129,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 127,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sLapras, moves := #[mBlizzard, mThunderbolt, mBodySlam, mSing] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 126,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mSing, mThunderWave] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mPsychic, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mAmnesia, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 125,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mSing] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mStunSpore, mExplosion] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mRest] }
    ] },
  { usage := 124,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mCounter] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mEggBomb] },
      { species := sGolem, moves := #[mEarthquake, mSubstitute, mBodySlam, mExplosion] },
      { species := sLapras, moves := #[mBlizzard, mConfuseRay, mBodySlam, mThunderbolt] },
      { species := sStarmie, moves := #[mBlizzard, mPsychic, mThunderbolt, mRecover] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 123,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mThunderWave, mSing] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mThunderWave, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 122,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sDodrio, moves := #[mBodySlam, mHyperBeam, mDrillPeck, mAgility] },
      { species := sKangaskhan, moves := #[mBodySlam, mHyperBeam, mEarthquake, mCounter] },
      { species := sPersian, moves := #[mSlash, mHyperBeam, mBodySlam, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 122,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 122,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 120,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mThunderWave, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 120,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSing, mIceBeam] },
      { species := sGengar, moves := #[mHypnosis, mNightShade, mExplosion, mThunderbolt] },
      { species := sMew, moves := #[mSwordsDance, mSoftBoiled, mEarthquake, mBodySlam] },
      { species := sMewtwo, moves := #[mAmnesia, mIceBeam, mRecover, mPsychic] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mRest, mSurf] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] }
    ] },
  { usage := 119,
    sets := #[
      { species := sCloyster, moves := #[mBlizzard, mExplosion, mClamp, mTriAttack] },
      { species := sElectrode, moves := #[mThunderWave, mThunderbolt, mExplosion, mScreech] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mConfuseRay, mThunderbolt] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] }
    ] },
  { usage := 118,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mRest, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderWave, mThunderbolt, mAgility] }
    ] },
  { usage := 118,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mMegaDrain] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mBodySlam, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mCounter, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 117,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mSeismicToss, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] },
      { species := sVictreebel, moves := #[mWrap, mRazorLeaf, mSleepPowder, mHyperBeam] }
    ] },
  { usage := 116,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mAmnesia, mSelfDestruct, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderWave, mDrillPeck, mThunderbolt, mAgility] }
    ] },
  { usage := 115,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mReflect] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mHyperBeam] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mPsychic, mThunderbolt] },
      { species := sGolbat, moves := #[mConfuseRay, mDoubleEdge, mScreech, mMegaDrain] },
      { species := sRaichu, moves := #[mThunderWave, mThunderbolt, mDoubleEdge, mSubmission] },
      { species := sSandslash, moves := #[mEarthquake, mSwordsDance, mBodySlam, mHyperBeam] }
    ] },
  { usage := 115,
    sets := #[
      { species := sCloyster, moves := #[mBlizzard, mExplosion, mClamp, mHyperBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 110,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mHyperBeam] },
      { species := sJolteon, moves := #[mThunderbolt, mDoubleKick, mThunderWave, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mAmnesia] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 109,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sGengar, moves := #[mExplosion, mThunderbolt, mHypnosis, mPsychic] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 109,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 108,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mReflect] },
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mExplosion, mPsychic, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mRockSlide, mBodySlam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 104,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mReflect] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mRest, mExplosion] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 103,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mRest, mPsychic] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sStarmie, moves := #[mThunderWave, mSurf, mRecover, mThunderbolt] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 100,
    sets := #[
      { species := sArcanine, moves := #[mBodySlam, mFireBlast, mHyperBeam, mAgility] },
      { species := sFearow, moves := #[mDrillPeck, mDoubleEdge, mHyperBeam, mAgility] },
      { species := sGastly, moves := #[mPsychic, mHypnosis, mThunderbolt, mExplosion] },
      { species := sNidoqueen, moves := #[mEarthquake, mThunderbolt, mBlizzard, mSubstitute] },
      { species := sSeaking, moves := #[mSurf, mAgility, mBlizzard, mHyperBeam] },
      { species := sStaryu, moves := #[mThunderWave, mSurf, mThunderbolt, mRecover] }
    ] },
  { usage := 100,
    sets := #[
      { species := sFlareon, moves := #[mBodySlam, mFireBlast, mQuickAttack, mHyperBeam] },
      { species := sParasect, moves := #[mSpore, mBodySlam, mStunSpore, mMegaDrain] },
      { species := sPidgeot, moves := #[mDoubleEdge, mHyperBeam, mAgility, mReflect] },
      { species := sPrimeape, moves := #[mRockSlide, mSeismicToss, mHyperBeam, mBodySlam] },
      { species := sSandslash, moves := #[mEarthquake, mRockSlide, mSwordsDance, mSubstitute] },
      { species := sTentacool, moves := #[mSurf, mBlizzard, mHydroPump, mWrap] }
    ] },
  { usage := 99,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSing, mIceBeam, mSoftBoiled, mThunderWave] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 99,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSoftBoiled, mThunderWave, mSing] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mRockSlide, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVenusaur, moves := #[mSleepPowder, mRazorLeaf, mSwordsDance, mHyperBeam] }
    ] },
  { usage := 98,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mReflect] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sLapras, moves := #[mBlizzard, mSing, mThunderbolt, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 97,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sGengar, moves := #[mHypnosis, mThunderbolt, mExplosion, mPsychic] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mAmnesia, mRest, mReflect] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 97,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mStunSpore, mSleepPowder] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] }
    ] },
  { usage := 96,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mReflect] },
      { species := sExeggutor, moves := #[mSleepPowder, mExplosion, mPsychic, mStunSpore] },
      { species := sGengar, moves := #[mConfuseRay, mThunderbolt, mHypnosis, mPsychic] },
      { species := sLapras, moves := #[mBlizzard, mBodySlam, mConfuseRay, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mAmnesia, mIceBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 96,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mRockSlide, mBodySlam] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mRest, mSurf] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mThunderbolt, mRecover] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 95,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mBlizzard, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 94,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 94,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSing] },
      { species := sLapras, moves := #[mBlizzard, mSing, mThunderbolt, mBodySlam] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 93,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sDragonite, moves := #[mWrap, mAgility, mHyperBeam, mBlizzard] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 92,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mAgility, mIceBeam, mDoubleEdge] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mCounter, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mIceBeam] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 92,
    sets := #[
      { species := sExeggutor, moves := #[mExplosion, mPsychic, mStunSpore, mSleepPowder] },
      { species := sGengar, moves := #[mExplosion, mThunderbolt, mHypnosis, mNightShade] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mIceBeam, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mBlizzard, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 91,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sDragonite, moves := #[mWrap, mThunderWave, mBlizzard, mHyperBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mCounter] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mSleepPowder, mWrap, mRazorLeaf, mStunSpore] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 91,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sGengar, moves := #[mExplosion, mThunderbolt, mHypnosis, mNightShade] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 90,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderWave, mDrillPeck, mThunderbolt, mAgility] }
    ] },
  { usage := 90,
    sets := #[
      { species := sChansey, moves := #[mDefenseCurl, mThunderWave, mSoftBoiled, mSeismicToss] },
      { species := sExeggutor, moves := #[mSleepPowder, mExplosion, mPsychic, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSlowbro, moves := #[mAmnesia, mReflect, mRest, mSurf] },
      { species := sStarmie, moves := #[mIceBeam, mThunderWave, mThunderbolt, mRecover] },
      { species := sWigglytuff, moves := #[mThunderWave, mBodySlam, mDefenseCurl, mRest] }
    ] },
  { usage := 90,
    sets := #[
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mHyperBeam, mSelfDestruct, mAmnesia] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mAgility] }
    ] },
  { usage := 89,
    sets := #[
      { species := sArticuno, moves := #[mBlizzard, mIceBeam, mAgility, mHyperBeam] },
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderWave, mThunderbolt, mAgility] }
    ] },
  { usage := 89,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sGengar, moves := #[mExplosion, mThunderbolt, mHypnosis, mNightShade] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 88,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sDragonite, moves := #[mWrap, mAgility, mBlizzard, mHyperBeam] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSnorlax, moves := #[mAmnesia, mBodySlam, mReflect, mIceBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 87,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mHyperBeam] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mCounter] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 86,
    sets := #[
      { species := sBeedrill, moves := #[mSwordsDance, mTwineedle, mAgility, mHyperBeam] },
      { species := sButterfree, moves := #[mPsychic, mStunSpore, mSleepPowder, mMegaDrain] },
      { species := sParasect, moves := #[mSpore, mStunSpore, mSlash, mMegaDrain] },
      { species := sPinsir, moves := #[mSwordsDance, mBodySlam, mHyperBeam, mSubmission] },
      { species := sScyther, moves := #[mSwordsDance, mHyperBeam, mSlash, mAgility] },
      { species := sVenomoth, moves := #[mPsychic, mSleepPowder, mStunSpore, mMegaDrain] }
    ] },
  { usage := 85,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mReflect] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 84,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mSing, mThunderWave] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mThunderWave, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mIceBeam] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 84,
    sets := #[
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sMew, moves := #[mSwordsDance, mEarthquake, mThunderWave, mSoftBoiled] },
      { species := sMewtwo, moves := #[mAmnesia, mRecover, mPsychic, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mAmnesia, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mEarthquake, mBlizzard] },
      { species := sZapdos, moves := #[mThunderWave, mThunderbolt, mDrillPeck, mAgility] }
    ] },
  { usage := 83,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mCounter] },
      { species := sLapras, moves := #[mBlizzard, mBodySlam, mThunderbolt, mConfuseRay] },
      { species := sRaichu, moves := #[mBodySlam, mThunderbolt, mHyperBeam, mThunderWave] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mBlizzard, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 83,
    sets := #[
      { species := sBlastoise, moves := #[mSurf, mSeismicToss, mBodySlam, mCounter] },
      { species := sCharizard, moves := #[mFireBlast, mBodySlam, mEarthquake, mSwordsDance] },
      { species := sClefable, moves := #[mBodySlam, mThunderWave, mBlizzard, mThunderbolt] },
      { species := sMrMime, moves := #[mThunderWave, mPsychic, mSeismicToss, mThunderbolt] },
      { species := sNidoking, moves := #[mEarthquake, mThunderbolt, mRockSlide, mBlizzard] },
      { species := sVenomoth, moves := #[mSleepPowder, mPsychic, mStunSpore, mDoubleEdge] }
    ] },
  { usage := 82,
    sets := #[
      { species := sDragonite, moves := #[mBlizzard, mBodySlam, mThunderbolt, mHyperBeam] },
      { species := sExeggutor, moves := #[mPsychic, mMegaDrain, mStunSpore, mSleepPowder] },
      { species := sGengar, moves := #[mThunderbolt, mPsychic, mHypnosis, mConfuseRay] },
      { species := sMagmar, moves := #[mConfuseRay, mBodySlam, mFireBlast, mSubmission] },
      { species := sPoliwrath, moves := #[mAmnesia, mHypnosis, mBlizzard, mPsychic] },
      { species := sRaichu, moves := #[mThunderWave, mBodySlam, mThunderbolt, mDoubleEdge] }
    ] },
  { usage := 80,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mReflect] },
      { species := sArticuno, moves := #[mBlizzard, mMimic, mReflect, mRest] },
      { species := sGengar, moves := #[mHypnosis, mPsychic, mThunderbolt, mExplosion] },
      { species := sSnorlax, moves := #[mBlizzard, mAmnesia, mReflect, mHyperBeam] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mThunderbolt] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderbolt, mThunderWave, mLightScreen] }
    ] },
  { usage := 80,
    sets := #[
      { species := sBlastoise, moves := #[mSurf, mSeismicToss, mCounter, mBodySlam] },
      { species := sCharizard, moves := #[mBodySlam, mEarthquake, mSlash, mSwordsDance] },
      { species := sClefable, moves := #[mThunderWave, mBodySlam, mBlizzard, mThunderbolt] },
      { species := sGolem, moves := #[mEarthquake, mRockSlide, mSubstitute, mExplosion] },
      { species := sMrMime, moves := #[mThunderWave, mPsychic, mSeismicToss, mThunderbolt] },
      { species := sVenomoth, moves := #[mSleepPowder, mPsychic, mStunSpore, mDoubleEdge] }
    ] },
  { usage := 80,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSing] },
      { species := sCloyster, moves := #[mClamp, mBlizzard, mExplosion, mRest] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mSubstitute, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 80,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mSeismicToss] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mThunderbolt, mPsychic] },
      { species := sJynx, moves := #[mLovelyKiss, mPsychic, mBlizzard, mIceBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 79,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mSing, mThunderWave] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mReflect, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 78,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mIceBeam, mThunderbolt, mSoftBoiled, mThunderWave] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mMegaDrain] },
      { species := sGengar, moves := #[mHypnosis, mConfuseRay, mPsychic, mExplosion] },
      { species := sStarmie, moves := #[mThunderWave, mThunderbolt, mIceBeam, mPsychic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 78,
    sets := #[
      { species := sBlastoise, moves := #[mHydroPump, mEarthquake, mBlizzard, mBodySlam] },
      { species := sCharizard, moves := #[mEarthquake, mFireBlast, mFlamethrower, mFireSpin] },
      { species := sLapras, moves := #[mBlizzard, mIceBeam, mConfuseRay, mHydroPump] },
      { species := sPikachu, moves := #[mThunderbolt, mThunderWave, mThunder, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mEarthquake, mHyperBeam, mAmnesia] },
      { species := sVenusaur, moves := #[mRazorLeaf, mSleepPowder, mSwordsDance, mHyperBeam] }
    ] },
  { usage := 78,
    sets := #[
      { species := sChansey, moves := #[mBlizzard, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mExplosion, mPsychic, mStrength, mMegaDrain] },
      { species := sGolem, moves := #[mEarthquake, mRockSlide, mExplosion, mCounter] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mSeismicToss, mPsychic] },
      { species := sSnorlax, moves := #[mBodySlam, mCounter, mEarthquake, mRockSlide] },
      { species := sStarmie, moves := #[mSurf, mBlizzard, mThunderbolt, mPsychic] }
    ] },
  { usage := 78,
    sets := #[
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mIceBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mStunSpore, mExplosion] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 76,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mIceBeam, mSoftBoiled, mThunderbolt] },
      { species := sDragonite, moves := #[mWrap, mAgility, mHyperBeam, mBlizzard] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mAmnesia, mReflect, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 76,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mRest, mSurf] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 76,
    sets := #[
      { species := sChansey, moves := #[mSing, mSoftBoiled, mThunderWave, mIceBeam] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sMoltres, moves := #[mFireBlast, mFireSpin, mAgility, mHyperBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mThunderbolt] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 76,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mReflect, mIceBeam, mSoftBoiled] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sPersian, moves := #[mSlash, mBubbleBeam, mThunderbolt, mHyperBeam] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mSubstitute, mBodySlam] },
      { species := sSlowbro, moves := #[mAmnesia, mSurf, mReflect, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mEarthquake, mRest] }
    ] },
  { usage := 75,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mStunSpore] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mPinMissile] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 75,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mThunderWave, mThunderbolt] },
      { species := sClefable, moves := #[mSing, mThunderWave, mBlizzard, mMegaKick] },
      { species := sKangaskhan, moves := #[mBodySlam, mHyperBeam, mEarthquake, mCounter] },
      { species := sPersian, moves := #[mSlash, mBodySlam, mThunderbolt, mHyperBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 74,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mRecover, mSeismicToss] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mStunSpore] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mThunderbolt, mNightShade] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mPinMissile, mDoubleKick] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mCounter] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 74,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mAmnesia, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderWave, mThunderbolt, mThunder] }
    ] },
  { usage := 74,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mSing] },
      { species := sMew, moves := #[mSwordsDance, mEarthquake, mSoftBoiled, mHyperBeam] },
      { species := sMewtwo, moves := #[mAmnesia, mPsychic, mRecover, mIceBeam] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mEarthquake, mHyperBeam] },
      { species := sZapdos, moves := #[mThunderWave, mThunderbolt, mDrillPeck, mAgility] }
    ] },
  { usage := 73,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mSing, mSoftBoiled, mThunderbolt] },
      { species := sCharizard, moves := #[mBodySlam, mSwordsDance, mHyperBeam, mEarthquake] },
      { species := sCloyster, moves := #[mBlizzard, mClamp, mHyperBeam, mExplosion] },
      { species := sGengar, moves := #[mPsychic, mHypnosis, mExplosion, mThunderbolt] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sStarmie, moves := #[mBlizzard, mThunderWave, mRecover, mThunderbolt] }
    ] },
  { usage := 73,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSeismicToss, mSing, mSoftBoiled] },
      { species := sDragonite, moves := #[mWrap, mAgility, mBlizzard, mHyperBeam] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mPsychic, mThunderbolt] },
      { species := sLapras, moves := #[mBlizzard, mBodySlam, mSing, mThunderbolt] },
      { species := sSnorlax, moves := #[mBodySlam, mHyperBeam, mSelfDestruct, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 73,
    sets := #[
      { species := sDragonite, moves := #[mWrap, mBlizzard, mAgility, mThunderWave] },
      { species := sDugtrio, moves := #[mEarthquake, mRockSlide, mSubstitute, mToxic] },
      { species := sHypno, moves := #[mHypnosis, mPsychic, mThunderWave, mRest] },
      { species := sKadabra, moves := #[mThunderWave, mSeismicToss, mPsychic, mRecover] },
      { species := sTentacruel, moves := #[mWrap, mSurf, mBlizzard, mRest] },
      { species := sVaporeon, moves := #[mBodySlam, mSurf, mBlizzard, mRest] }
    ] },
  { usage := 72,
    sets := #[
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mExplosion, mSleepPowder, mStunSpore] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mThunderbolt, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 72,
    sets := #[
      { species := sCloyster, moves := #[mBlizzard, mClamp, mExplosion, mToxic] },
      { species := sDragonite, moves := #[mWrap, mAgility, mHyperBeam, mBlizzard] },
      { species := sGengar, moves := #[mExplosion, mHypnosis, mThunderbolt, mToxic] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mSleepPowder, mWrap, mRazorLeaf, mStunSpore] },
      { species := sZapdos, moves := #[mDrillPeck, mThunderWave, mThunderbolt, mLightScreen] }
    ] },
  { usage := 71,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mMegaDrain] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mEarthquake, mReflect] },
      { species := sStarmie, moves := #[mThunderWave, mThunderbolt, mBlizzard, mRecover] }
    ] },
  { usage := 71,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mReflect] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mBodySlam, mRockSlide] },
      { species := sSnorlax, moves := #[mBodySlam, mCounter, mSelfDestruct, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mSleepPowder, mRazorLeaf, mWrap, mSwordsDance] }
    ] },
  { usage := 71,
    sets := #[
      { species := sChansey, moves := #[mIceBeam, mThunderWave, mSoftBoiled, mReflect] },
      { species := sGengar, moves := #[mHypnosis, mExplosion, mNightShade, mThunderbolt] },
      { species := sKingler, moves := #[mSwordsDance, mHyperBeam, mCrabhammer, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mSelfDestruct, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sZapdos, moves := #[mThunderbolt, mDrillPeck, mThunderWave, mAgility] }
    ] },
  { usage := 71,
    sets := #[
      { species := sGolem, moves := #[mEarthquake, mExplosion, mBodySlam, mRockSlide] },
      { species := sHypno, moves := #[mHypnosis, mThunderWave, mSeismicToss, mPsychic] },
      { species := sJolteon, moves := #[mThunderWave, mThunderbolt, mDoubleKick, mRest] },
      { species := sLapras, moves := #[mBlizzard, mBodySlam, mThunderbolt, mHyperBeam] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mHyperBeam, mEarthquake] },
      { species := sTauros, moves := #[mBodySlam, mBlizzard, mHyperBeam, mEarthquake] }
    ] },
  { usage := 70,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mRecover, mSeismicToss] },
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mLeechSeed, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mRest, mSurf] },
      { species := sSnorlax, moves := #[mAmnesia, mReflect, mBodySlam, mRest] }
    ] },
  { usage := 70,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mSeismicToss, mIceBeam] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mDoubleEdge] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] },
      { species := sVictreebel, moves := #[mWrap, mRazorLeaf, mSleepPowder, mStunSpore] }
    ] },
  { usage := 70,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mSoftBoiled, mIceBeam, mSing, mThunderWave] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSlowbro, moves := #[mAmnesia, mThunderWave, mSurf, mRest] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mAmnesia] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 70,
    sets := #[
      { species := sAlakazam, moves := #[mPsychic, mThunderWave, mReflect, mRecover] },
      { species := sDragonite, moves := #[mWrap, mAgility, mBlizzard, mHyperBeam] },
      { species := sExeggutor, moves := #[mSleepPowder, mPsychic, mExplosion, mHyperBeam] },
      { species := sLapras, moves := #[mConfuseRay, mBlizzard, mSing, mBodySlam] },
      { species := sSnorlax, moves := #[mBodySlam, mBlizzard, mHyperBeam, mSelfDestruct] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mThunderbolt] }
    ] },
  { usage := 69,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mSoftBoiled, mIceBeam, mThunderbolt] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mMegaDrain] },
      { species := sKingler, moves := #[mSwordsDance, mHyperBeam, mBodySlam, mCrabhammer] },
      { species := sSnorlax, moves := #[mBodySlam, mSelfDestruct, mReflect, mRest] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 69,
    sets := #[
      { species := sChansey, moves := #[mSoftBoiled, mThunderWave, mSeismicToss, mIceBeam] },
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mSubstitute, mRockSlide, mBodySlam] },
      { species := sSlowbro, moves := #[mAmnesia, mRest, mThunderWave, mSurf] },
      { species := sSnorlax, moves := #[mBodySlam, mRest, mReflect, mAmnesia] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mPsychic, mBlizzard] }
    ] },
  { usage := 68,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mSleepPowder, mExplosion, mMegaDrain] },
      { species := sJolteon, moves := #[mThunderbolt, mThunderWave, mDoubleKick, mRest] },
      { species := sJynx, moves := #[mPsychic, mLovelyKiss, mBlizzard, mCounter] },
      { species := sRhydon, moves := #[mEarthquake, mRockSlide, mBodySlam, mTailWhip] },
      { species := sStarmie, moves := #[mThunderWave, mPsychic, mRecover, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mBlizzard, mFireBlast, mThunderbolt] }
    ] },
  { usage := 68,
    sets := #[
      { species := sGyarados, moves := #[mBodySlam, mBlizzard, mHydroPump, mHyperBeam] },
      { species := sHypno, moves := #[mThunderWave, mSeismicToss, mRest, mPsychic] },
      { species := sKadabra, moves := #[mThunderWave, mSeismicToss, mPsychic, mRecover] },
      { species := sKangaskhan, moves := #[mBodySlam, mHyperBeam, mEarthquake, mCounter] },
      { species := sPersian, moves := #[mSlash, mHyperBeam, mThunderbolt, mToxic] },
      { species := sTentacruel, moves := #[mWrap, mSurf, mBlizzard, mRest] }
    ] },
  { usage := 67,
    sets := #[
      { species := sExeggutor, moves := #[mPsychic, mStunSpore, mExplosion, mSleepPowder] },
      { species := sJynx, moves := #[mLovelyKiss, mBlizzard, mPsychic, mRest] },
      { species := sRhydon, moves := #[mEarthquake, mBodySlam, mRockSlide, mSubstitute] },
      { species := sSnorlax, moves := #[mBodySlam, mReflect, mRest, mSelfDestruct] },
      { species := sStarmie, moves := #[mThunderWave, mRecover, mThunderbolt, mBlizzard] },
      { species := sTauros, moves := #[mBodySlam, mHyperBeam, mBlizzard, mEarthquake] }
    ] },
  { usage := 66,
    sets := #[
      { species := sAlakazam, moves := #[mThunderWave, mPsychic, mSeismicToss, mRecover] },
      { species := sChansey, moves := #[mThunderWave, mBlizzard, mSoftBoiled, mThunderbolt] },
      { species := sGolem, moves := #[mEarthquake, mExplosion, mRockSlide, mCounter] },
      { species := sParasect, moves := #[mSlash, mSpore, mMegaDrain, mLeechLife] },
      { species := sSnorlax, moves := #[mBodySlam, mCounter, mEarthquake, mRockSlide] },
      { species := sTauros, moves := #[mBodySlam, mBlizzard, mThunderbolt, mEarthquake] }
    ] }
]

private def representativeMon (set : Set) : MonState :=
  let generated := genMon (speciesEntry set.species) 100 15 15 15 15 4
  { generated with moves := set.moves, pp := set.moves.map movePP }

private def representativeTeam (entry : Entry) : Team :=
  entry.sets.map representativeMon

/-- Every inferred set is a full canonical level-100 cartridge team. -/
@[simp] theorem teams_complete_and_legal :
    teams.size = 200 ∧ teams.all (fun entry =>
      entry.sets.size == 6 && entry.sets.all (fun set =>
        set.moves.size == 4 && Data.isRealSpecies set.species &&
          entry.sets.foldl (fun count other =>
            if other.species == set.species then count + 1 else count) 0 == 1) &&
      teamLegal genDex .canonical (representativeTeam entry)) = true := by
  native_decide

/-- Observed composition usage remains positive and descending. -/
def usageDescending : Bool :=
  decide (teams.toList.Pairwise fun left right => left.usage ≥ right.usage)

@[simp] theorem usage_descending : usageDescending = true := by
  native_decide

end Battle.RL.PopularTeams
