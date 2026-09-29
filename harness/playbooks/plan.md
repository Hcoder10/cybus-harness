# Planning a game from a pitch

Output a short game design document the whole team builds against. Be concrete and scope for the time
budget: one polished vertical slice beats five broken features.

1. **Fantasy and hook**: one sentence of what the player feels; the hook that makes someone click play.
2. **Core loop**: the 10-60 second loop (action -> feedback -> reward -> next decision), written as steps.
   Name the verbs and the input for each (touch / mouse+keyboard / gamepad).
3. **Signature moment**: the one moment players will remember and clip (a perfect catch, a photo finish,
   the lights going out, the last wave). It gets the most craft: camera, VFX, audio, UI.
4. **Session shape**: first 60 seconds (title -> play, zero confusion), a round or day, and the end state
   (results, rewards, replay).
5. **Systems list**: each system with its responsibility, its data, its owner module, and its test. Keep
   the list short. Client-server split and what must be server-authoritative.
6. **Screens and HUD list**: title/menu, HUD, results, shop/inventory if needed, settings; for each, its job
   and the one thing that must read first.
7. **Content list**: world areas, props, characters/NPCs, items, sounds, music tracks; mark which are
   generated (image generation), built from primitives, or taken from the Roblox library.
8. **Aspects plan**: for each aspect (ui_menus, hud, camera, game_feel, vfx, animation, world_art,
   characters, audio_design, core_loop, cohesion, polish): what "done" looks like for THIS game and how it
   will be captured for judging (which screens, which moments, which frames).
9. **Order of work**: scaffold -> core loop greybox playable -> style applied -> signature moment ->
   UI/HUD -> world art -> VFX/audio/feel pass -> integration playtest -> polish panel.
10. **Risks**: the two things most likely to go wrong and how to detect them early.
