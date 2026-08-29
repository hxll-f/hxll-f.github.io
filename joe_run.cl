// Reconstructs a specific Red Deck / White Stake run, transcribed by hand
// from a video, ante by ante. Scoring is additive (1 point per matched
// condition) rather than all-or-nothing, so you can see near-misses.
//
// Restructured as data-driven loops (rather than one straight-line call per
// condition) specifically to keep the compiled kernel small - each loop body
// is compiled once and iterated at runtime, instead of ~100 near-identical
// call sites each getting separately inlined by the OpenCL compiler. This
// matters a lot on backends (NVIDIA's in particular) that scale build time
// badly with kernel size.
//
// Max achievable score if every known condition matches: 103
//   Ante 1: 15   Ante 2: 32   Ante 3: 18   Ante 4: 22   Ante 5: 15   Ante 8: 1
//
// Run with, e.g.:
//   immolate -f joe_run -c 90 -n 100000000 -g 256
// and lower -c if nothing turns up near 103. FIXED_FILTER_CUTOFF (below)
// prints every seed clearing -c, not just the single best one.
//
// ===================== CAVEATS - read before trusting a "perfect" hit =====================
// 1. PACK SIZES: verified against the current Balatro Wiki - Buffoon Pack and
//    Spectral Pack are 2/4/4 cards (Normal/Jumbo/Mega), Arcana/Celestial/
//    Standard are 3/5/5. This matches the engine's own PACK_INFO table
//    exactly. Five spots in the transcript listed one more card than that
//    pack size can hold; per source-video review the dropped items are:
//    Ante 1 Shop 1 Pack 1 (Banner), Ante 2 Shop 1 Pack 2 (Even Steven),
//    Ante 2 Shop 2 Pack 2 (Ouija - The Soul itself IS kept as a checked
//    card), Ante 2 Shop 3 Pack 2 (Faceless Joker), Ante 3 Shop 1 Pack 1
//    (Grim), Ante 4's Buffoon Tag reward (Erosion).
// 2. VOUCHER TIMING: each ante's voucher is assumed bought immediately
//    (before any shop item is drawn that ante), which matters because
//    active vouchers shift shop item type-weights. If it was actually
//    bought mid-shop, move the activate_voucher() call to match.
// 3. UNRECORDED SECTIONS score nothing (RETRY is used as a "no data, don't
//    check" sentinel in the per-ante tables below) but boss, voucher, and
//    tags are still drawn for every ante 1-8 regardless, to keep the RNG
//    streams positioned correctly - see caveat #4.
// 4. BOSS SELECTION has no ante key at all - it's a single global sequential
//    draw with a shrinking/reopening lock pool. That means next_boss() has
//    to be called once for EVERY ante from 1 to 8 in order, even antes with
//    no other data, or Ante 8's boss check would read the wrong draw.
// 5. Buffoon Tag's free pack and Judgement's joker are reconstructed from
//    the RNG-source enums in lib/cache.cl (S_Judgement, and a direct
//    buffoon_pack() call for the tag reward) rather than copied from an
//    existing filter doing the same thing. Worth a sanity check if the
//    score comes up suspiciously short around Ante 4.
// ============================================================================

#define CACHE_SIZE 200
#define FIXED_FILTER_CUTOFF
#include "lib/immolate.cl"

// Draws the next pack for `ante`, generates its contents, and returns how
// many points it earned: 1 for matching `expectedType`, plus 1 per matched
// card (in order) against `expected`, up to `expectedCount`. Pass
// expectedCount = 0 for packs whose contents weren't recorded - still
// consumes the stream correctly, just isn't content-checked (`expected`'s
// contents are irrelevant in that case, never read).
int check_pack(instance* inst, int ante, item expectedType, item expected[], int expectedCount) {
    item packType = next_pack(inst, ante);
    int points = (packType == expectedType) ? 1 : 0;

    pack info = pack_info(packType);
    int size = info.size;

    item cards[5];
    if (info.type == Arcana_Pack) arcana_pack(cards, size, inst, ante);
    else if (info.type == Celestial_Pack) celestial_pack(cards, size, inst, ante);
    else if (info.type == Spectral_Pack) spectral_pack(cards, size, inst, ante);
    else if (info.type == Buffoon_Pack) buffoon_pack(cards, size, inst, ante);
    else if (info.type == Standard_Pack) {
        card stdCards[5];
        standard_pack(stdCards, size, inst, ante);
        return points; // playing-card contents not modeled - not needed for this run
    } else return points;

    for (int i = 0; i < expectedCount && i < size; i++) {
        if (cards[i] == expected[i]) points++;
    }
    return points;
}

long filter(instance* inst) {
    set_deck(inst, Red_Deck);
    set_stake(inst, White_Stake);
    init_locks(inst, 1, false, true);

    int score = 0;

    // ===================== Boss / Voucher / Tags, all 8 antes =====================
    // RETRY means "not recorded - roll it to keep streams aligned, don't score it".
    item bossExpected[9]     = {RETRY, The_Window,   The_Psychic, The_Ox,        The_Needle,   RETRY, RETRY, RETRY, Violet_Vessel};
    item voucherExpected[9]  = {RETRY, Tarot_Merchant, Crystal_Ball, Overstock, Directors_Cut, Overstock_Plus, RETRY, RETRY, RETRY};
    item tagSBExpected[9]    = {RETRY, Standard_Tag,  Double_Tag,  Double_Tag,    Buffoon_Tag,  RETRY, RETRY, RETRY, RETRY};
    item tagBBExpected[9]    = {RETRY, Charm_Tag,     Garbage_Tag, Investment_Tag, Rare_Tag,    RETRY, RETRY, RETRY, RETRY};

    for (int ante = 1; ante <= 8; ante++) {
        init_unlocks(inst, ante, false);

        if (next_boss(inst, ante) == bossExpected[ante]) score++;

        item voucher = next_voucher(inst, ante);
        if (voucher == voucherExpected[ante]) score++;
        activate_voucher(inst, voucher); // caveat #2

        if (next_tag(inst, ante) == tagSBExpected[ante]) score++;
        if (next_tag(inst, ante) == tagBBExpected[ante]) score++;
        next_orbital_tag(inst); // burn call - see lib/filters/analyzer.cl

        // Ante-specific one-off mechanics that don't fit the generic table:
        if (ante == 2) {
            // Soul (drawn inside the Ante 2 Shop 2 pack, see pack table below) was used, producing Triboulet
            if (next_joker(inst, S_Soul, 2) == Triboulet) score++;
        }
        if (ante == 4) {
            // Buffoon Tag's free Mega Buffoon Pack bypasses next_pack - the type
            // is fixed by the tag, not rolled.
            item buffoonTagCards[4];
            buffoon_pack(buffoonTagCards, pack_info(Mega_Buffoon_Pack).size, inst, 4); // size 4, verified - caveat #1
            item a4skipSB[] = {Oops_All_6s, The_Trio, Throwback, Mystic_Summit}; // Erosion dropped - pack only holds 4
            for (int i = 0; i < 4; i++) if (buffoonTagCards[i] == a4skipSB[i]) score++;

            // Big-Blind-skip Rare Tag reward resolves against ante+1 - a real
            // engine quirk (see lib/filters/analyzer.cl's print_tag_info).
            if (next_joker(inst, S_Rare_Tag, 5) == Baseball_Card) score++;

            // Judgement was used on a joker, producing Riff Raff
            if (next_joker(inst, S_Judgement, 4) == Riff_raff) score++;
        }
    }

    // ===================== Shop items, all antes in order =====================
    // Order within an ante must be exactly the recorded reveal order (rerolls
    // just continue the same per-ante stream); order between different antes
    // doesn't matter, since each ante's shop stream is independently keyed.
    int shopAnte[] = {
        1,1, 1,1,                                    // Ante 1: Shop 1, Shop 2
        2,2, 2,2, 2,2, 2,2,                           // Ante 2: Shop 1, Shop 2, Shop 3, Shop 3 reroll
        3,3,3,                                        // Ante 3: Shop 1 (incl. post-Overstock slot)
        4,4,4,                                        // Ante 4: Shop 1
        5,5,5,5,5, 5,5,5,5                            // Ante 5: Shop 1 (5 draws), reroll (4 draws)
    };
    item shopExpected[] = {
        The_Moon, Burglar, Blackboard, Blueprint,
        Satellite, Mercury, The_Hierophant, Bloodstone, Stone_Joker, Ancient_Joker, Satellite, Pluto,
        Ramen, Arrowhead, Wrathful_Joker,
        The_Family, Ramen, Reserved_Parking,
        Mercury, Matador, The_Family, Joker, The_Devil, Temperance, The_Moon, Jupiter, The_Tribe
    };
    int shopCount = sizeof(shopAnte) / sizeof(shopAnte[0]);
    for (int i = 0; i < shopCount; i++) {
        if (next_shop_item(inst, shopAnte[i]).value == shopExpected[i]) score++;
    }

    // ===================== Booster packs, all antes in order =====================
    // Same independence rule as shop items: order within an ante's pack
    // stream matters, order relative to other antes doesn't.
    int packAnte[]       = {1,          1,                1,             1,
                             2,                2,          2,              2,             2,
                             3,                 3,
                             4,          4,
                             5,               5};
    item packType_[]     = {Buffoon_Pack, Jumbo_Arcana_Pack, Buffoon_Pack, Jumbo_Arcana_Pack,
                             Jumbo_Celestial_Pack, Mega_Buffoon_Pack, Jumbo_Celestial_Pack, Spectral_Pack, Arcana_Pack,
                             Mega_Spectral_Pack, Jumbo_Celestial_Pack,
                             Arcana_Pack, Jumbo_Arcana_Pack,
                             Celestial_Pack, Mega_Arcana_Pack};
    int packContentCount[] = {2, 0, 0, 0,
                               0, 4, 0, 2, 3,
                               4, 5,
                               3, 4,
                               3, 0};
    // Ante 2 Shop 3 Pack 2 (Jumbo Buffoon Pack) is intentionally not in the
    // arrays above - see below, it needs its own row.
    item packContent[15][5] = {
        {Photograph, Shortcut},                                        // Ante 1 Shop 1 Pack 1
        {0},                                                           // Ante 1 Shop 1 Pack 2 (unrecorded)
        {0},                                                           // Ante 1 Shop 2 Pack 1 (unrecorded)
        {0},                                                           // Ante 1 Shop 2 Pack 2 (unrecorded)
        {0},                                                           // Ante 2 Shop 1 Pack 1 (unrecorded)
        {Golden_Joker, Fibonacci, To_Do_List, Merry_Andy},              // Ante 2 Shop 1 Pack 2
        {0},                                                           // Ante 2 Shop 2 Pack 1 (unrecorded)
        {Ectoplasm, The_Soul},                                         // Ante 2 Shop 2 Pack 2
        {The_Wheel_of_Fortune, The_Hermit, The_Chariot},                // Ante 2 Shop 3 Pack 1
        {Medium, Trance, Black_Hole, Sigil},                            // Ante 3 Shop 1 Pack 1
        {Neptune, Earth, Mars, Jupiter, Uranus},                        // Ante 3 Shop 1 Pack 2
        {The_Star, Justice, The_Hierophant},                            // Ante 4 Shop 1 Pack 1
        {The_Chariot, The_Hermit, The_Hierophant, The_High_Priestess},  // Ante 4 Shop 1 Pack 2
        {Pluto, Venus, Uranus},                                         // Ante 5 Shop 1 Pack 1
        {0}                                                            // Ante 5 Shop 1 Pack 2 (unrecorded)
    };
    int packN = sizeof(packAnte) / sizeof(packAnte[0]);
    for (int i = 0; i < packN; i++) {
        score += check_pack(inst, packAnte[i], packType_[i], packContent[i], packContentCount[i]);
    }
    // Ante 2 Shop 3 Pack 2 (Jumbo Buffoon Pack) - kept separate since it's
    // the only pack check that falls between two of the table entries above
    // in real reveal order but doesn't disturb correctness either way
    // (independent per-ante stream, see note above).
    item a2s3p2[] = {The_Duo, Gros_Michel, Scholar, Drivers_License};
    score += check_pack(inst, 2, Jumbo_Buffoon_Pack, a2s3p2, 4);

    return score;
}
