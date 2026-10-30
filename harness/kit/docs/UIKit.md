- UIKit (client; UI = require(ReplicatedStorage.Kit.UIKit)): BUILD EVERY HUD AND MENU WITH IT. Themed game UI on the 1920x1080
  canvas (positions/sizes are canvas px; Screen fits them). Looks finished with NO images (gradients, ink outlines, hard
  shadows, slanted plates); every image field (icon, portrait) takes an Assets name, "rbxassetid://..." or a number.
  Every component -> obj with obj:set(...), obj:show(), obj:hide(), obj:Destroy(), obj:punch(), obj.root; all animate in/out
  and on change. Common opts: position=UDim2, anchor=Vector2, parent=GuiObject, theme, hidden=true (start hidden).
- UI.theme("arcade"|"cozy"|"tactical"|"fantasy"|"toon", overrides?) -> theme (becomes current). arcade = slanted italic racer/
  action HUD; cozy = rounded warm sim/cooking; tactical = thin translucent military shooter; fantasy = gold-rimmed RPG;
  toon = bubbly N64/kids. Tokens' primary/secondary/success/warning/danger drive accents; overrides={tokens="all"|"none",
  c={accent=Color3,...}, skew=0.24, radius=12, stroke=3, tilt=-4, font={display=Font}}. UI.clear() destroys all components.
  UI.onSound = function(name) Sound.play(...) end  (names: hover click pop tick banner go check hit kill toast type reload stamp deny)
  UI.safeTop() canvas px below the Roblox top bar; UI.compact() phone layout; UI.layer(name?, order?) -> ScreenGui.
- UI.banner(text, {sub, color, textSize=150}) -> b:set(text, {sub, color}); b:flash(seconds, text?) (punch-in + shine, auto-hide)
- UI.countdown({go="GO!"}) -> c:start(from=3, onDone?, step=1); c:set(n | "GO!")
- UI.counter({label, value, icon|glyph, color, format}) -> c:set(value)  (rolls, pops, floats +delta); c.value
- UI.bar({label, value, max=100, color, width=440, height=34, segments, format="percent"|fmt, showText, lowAt=0.25})
  -> b:set(value, max?) (loss leaves a draining white chip, gain a leading green chip); b:setColor(c)
- UI.ring({value=0..1, size=128, label, color, icon|glyph}) -> r:set(frac, {color})
- UI.dial({max=200, redline, unit="KM/H", label, size=300}) -> d:set(value)  (sprung needle, lit segment band)
- UI.timer({seconds=60, countdown=true, warnAt=10, onDone, autoStart=true}) -> t:set(s); t:start(); t:stop(); t.seconds
- UI.objectiveTracker({title, items={"text" | {id, text, progress, max, done}}}) -> o:set(items); o:check(i|id); o:progress(i|id, n, max?)
- UI.standings({title, rows={{name, value, color, you=true}}, sortBy="value", max=8}) -> s:set(rows)  (rows spring to new rank)
- UI.minimap({range=300 studs, parts=Folder|{BasePart}, center=Vector3 (else follows the player), shape="circle"|"square", label})
  -> m:mark(id, {at=Vector3|BasePart|Model, color, glyph, pulse}); m:unmark(id); m:set({center, range, follow})
- UI.crosshair({style="cross"|"tee"|"dot"|"circle", gap, spread=40, length, thickness, color}) -> c:set({spread=0..1});
  c:kick(amount=1) (on fire); c:hit("hit"|"headshot"|"kill")
- UI.ammo({mag, magSize=30, reserve, weapon}) -> a:set(mag, reserve?); a:reload(seconds, onDone) (set new counts in onDone)
- UI.toast(text, {body, kind="info"|"good"|"warn"|"bad"|"reward", icon|glyph, duration=3}) -> {dismiss()}; UI.toasts(opts):push(...)
- UI.dialog({}) -> d:say(speaker, text, {portrait, color, speed=45, choices={"Yes","No"}, onChoice(i, label), onNext()}); d:skip()
- UI.prompt({key="E", label, adornee=BasePart? (world billboard)}) -> p:set(key, label); p:progress(0..1); p:press()
- UI.button({text, kind="primary"|"secondary"|"good"|"danger"|"neutral", color, icon|glyph, size=Vector2, onClick, enabled})
  -> b:set({text, kind, color, enabled})  (hover lift, press squish into its lip, deny shake when disabled)
- UI.panel({title, tabs={"ITEMS","SHOP"}, size=Vector2(960,620), backdrop=true, onTab(name), onClose}) -> p.content,
  p.pages[tab] (parent your content there); p:select(tab)
- UI.grid({columns=5, rows, slot=100, items={{name, icon|glyph, count, rarity="common"|"uncommon"|"rare"|"epic"|"legendary"|
  "mythic"}}, onSelect(i, item)}) -> g:set(items); g:setItem(i, item); g:select(i). UI.hotbar({items}) = 1-row grid, keys 1-9
- UI.shopCard({name, icon|glyph, rarity, price, currency="$", badge="NEW", owned, affordable, onBuy(card)}) -> c:set({price, owned, affordable})
- UI.results({title="VICTORY", sub, stats={{label, value}}, rank="S", rewards={{glyph|icon, count, color}}, buttons={{text, kind,
  onClick}}}) -> full-screen; rows stagger in and count up, rank stamp slams, rewards pop
- UI.damage(at=Vector3|BasePart|Model, amount, {kind="normal"|"crit"|"heal"|"block"|"miss"}); UI.popup("+1", {at=Vector3|
  BasePart|GuiObject|UDim2, color}) -- world ones are BillboardGuis that rise and fade
