# Poison Bucket

A rogue poison manager for **World of Warcraft 1.12** (vanilla / Turtle WoW). It watches your weapon poisons, lets you apply them with one click, and swaps weapon sets based on what you're fighting.

## Features

- **Poison alert** — when a weapon has no poison or fewer than 10 charges left, the bucket pulses red and a horn sounds 3 times (repeating every 30s) until you re-apply. Click the bucket to arm/disarm the alert.
- **Poison rack** — drag poisons from your bags onto the window to rack them. **Left-click** a racked poison to apply it to your **main hand**, **right-click** for the **off hand**. Shows a live count of how many you have left. Shift-click removes it from the rack.
- **Creature-aware weapon swap** — Elemental, Giant, Undead and Mechanical enemies need **Dissolvent Poison**; everything else takes standard poisons. When your target doesn't match your weapons, a pulsing swap button appears — click it to equip the right pair. Works in combat.
- **Auto-swap** — optionally swap automatically the moment you select a target.

## How to use

### 1. Set up your weapons and rack your poisons

Right-click the bucket to open the menu. Drag a weapon (from your bags or the character pane) into each slot — one pair for Dissolvent, one for standard poisons — or click **Use equipped** to save what you're holding. Drag between slots to move/swap, drag out to remove. Enable **Auto-swap on new target** if you want the swap to happen hands-free.

![Poison Bucket menu](https://pngup.com/Nrt2/Poison-bucket-menu.png)

### 2. Apply poisons

Drop poisons on the window to rack them, then left-click for main hand, right-click for off hand. The replace-confirmation is handled for you.

![Applying poisons](https://pngup.com/ESd2/apply-poisons.png)

### 3. Bind the swap key (optional)

`Esc → Key Bindings → Poison Bucket → Swap poison weapon set`. With a mismatch showing it equips the needed pair; otherwise it toggles between your two pairs.

![Keybind weapon swap](https://pngup.com/vIz8/Keybind-weapon-wap.png)

## Install

Copy the `PoisonBucket` folder into `Interface\AddOns\` and restart the client. Drag the bucket icon to move the window.

## Notes

- The rack quietly parks each racked poison on an unused action slot at the high end (120 downward) — that's what makes one-click applying work on this client. Un-racking frees the slot.
- If you run the full [HoryUI](https://github.com/Cinecom/0HoryUI) addon, Poison Bucket stays dormant — HoryUI ships this same module built in.
