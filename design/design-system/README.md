Valyn is a framed invoice dashboard: a pale sky-blue backdrop, one window with a photographic hero on top and a near-black working area below, and a single blue accent that marks whatever is selected. Everything here comes from one screenshot (`assets/Reference/valyn-invoices-reference.png`), so values are read off that image — sizes are as measured on a 1024px-wide frame.

## Content fundamentals
- Write plain, task-first copy: "Manage and track all your invoices in one place."
- Page and panel titles are Title Case nouns ("Invoices", "Unpaid Invoices"); tabs and nav items are single words ("Overview", "Estimates", "Invoices", "Payments").
- Status badges are one word: "Unsent", "Viewed". Due dates are relative: "In 2 days".
- Money is dollars with thousands separators and two decimals: `$68,750.00`. Invoice numbers read `# INV-1003`.
- The one call to action is a short verb phrase: "Payout now". No emoji.

## Visual foundations
- **Color.** Work on `surface-ground`; lift lists and cards to `surface-row`, chips to `surface-chip`. `brand-blue` is the only accent: use it for the selected row, the invoice detail panel, the active pill and the highlighted chart bar — never for decoration. Text is `text-primary`, secondary text `text-muted`; on blue use `on-brand`. `backdrop-sky` is only the canvas behind the window.
- **Type.** One sans family (`--font-sans`). Set the page title in `display`, headline numbers in `amount-lg`, panel headings in `heading`, rows in `body`, labels and badges in `caption`. Tight, quiet: weights 400 and 500 only.
- **Shape.** Round everything. The window and big panels use `radius-lg`, rows and tiles `radius-md`, small controls `radius-sm`, pills, badges and round icon buttons `radius-pill`.
- **Space.** Rows and tiles sit `space-2` apart, panels have `space-4` padding, panels sit `space-5` apart.
- **Surfaces.** Over photography, use frosted glass cards (translucent dark fill, blur) holding charts; inside the blue panel, use lighter frosted `brand-blue-tint` tiles. A dashed `radius-md` outline with a plus marks the "Add Item" empty slot. Only buttons carry a shadow (see Buttons); panels, rows and cards stay flat.
- **Imagery.** A full-bleed, close-cropped lifestyle photograph fills the top of the window behind the title; the dark working area slides up over its lower edge.
- **Selection.** The selected list row turns solid `brand-blue` and its badge inverts to a white pill with dark text; the matching detail panel uses the same blue.

## Buttons
Buttons are embossed with the `shadow` tokens: a 1px top highlight, a 2px bottom shade and a soft drop in one `box-shadow`. Primary actions use `brand-blue` with `emboss-blue` and `on-brand` text (14px weight 500 or larger). Secondary and icon buttons use `surface-chip` with `emboss-chip`. A segmented toggle runs on a `brand-blue` track; its selected thumb is `button-light` with `emboss-light` and `surface-ground` text, and slides between sides in about 0.22s. Press moves a button down 1px. Details and a live card are under Button in Components.

## Iconography
Thin, rounded outline glyphs (arrow, calendar, bell, link, plus) at caption size, in `text-primary` or `on-brand`. No icon files were supplied; none are included.

## Logo
No logo file was supplied. Set "Valyn" in plain `heading`-weight type; do not redraw the four-square mark seen in the screenshot.

## Not yet defined
Font files and the exact typeface (the stack in `--font-sans` is a stand-in), light-theme values, focus states, hover states, and the reference's own component specs. Ask before assuming them.
