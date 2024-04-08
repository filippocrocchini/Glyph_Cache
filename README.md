## Glyph_Cache

This is a module that helps you get text on screen quickly. Paired with [Harfbuzz](https://github.com/filippocrocchini/Harfbuzz) it lets you render any glyph in any font, any size, in any style including emojis*. You no longer need to preload some codepoints to generate a bitmap which you then use to render the text. The bitmap is generated for you, dynamically, based on the glyphs that you need.

*Many colored emoji fonts are not supported by freetype2, at least not the version shipped with the jai compiler. 

### Dependencies

- [Rect_Pack](https://github.com/filippocrocchini/Rect_Pack) 

### Usage

```jai
    Glyph_Cache.init_font_cache(width = 512, height = 512);
    defer Glyph_Cache.deinit_font_cache();
```

init_font_cache() needs to be called once, before you start requesting glyphs. deinit_font_cache() frees the buffer for the cache bitmap and other internal resources. 

Once it's initialized you can add fonts in the following ways, based on if you want to load it from a file or from memory.
```jai
    success_loading_from_file : bool = Glyph_Cache.add_font_from_file("Karla-Regular.ttf");

    buffer : []u8;
    success_loading_from_memory : bool = Glyph_Cache.add_font_from_memory(buffer);
```

Once this is done you can query which face, among the currently loaded ones, is the best fit for the style you want.

```jai
    font_face := Glyph_Cache.find_best_face_for_style(.{ 
        family = "Karla Regular", 
        style  = .NORMAL, 
        weight = .NORMAL,
        });
```

You can then bind a face and request glyphs either by codepoint or by index.

```jai
    Glyph_Cache.bind_face(font_face, pixels_per_em);

    glyph, found := Glyph_Cache.get_glyph_for_codepoint(codepoint);

    glyph_index  := 1;
    glyph, found := Glyph_Cache.get_glyph(glyph_index);
```

These are the useful members of the Cached_Glyph struct:

```jai
    x, y: int; // pixels
    w, h: int; // pixels
    bearing_x, bearing_y : int; // pixels (right handed)
    advance_x, advance_y : int; // pixels (right handed)
```
Note that all members of this struct have already been scaled so that you only need to simply use the values without major headaches. (Except the handedness.)

It is **crucial** that you update the texture before you render your glyphs, you will have to draw text in two passes (see the examples). Simp does the same thing, you prepare the text, then you render the prepared glyphs.

```jai
    dirty, bitmap := Glyph_Cache.peek_cache_bitmap(evict_after = 8);
    if dirty
    {
        // ... upload bitmap to GPU
    }
```
Here "evict_after=8" means that all glyphs that haven't been used in the last **7** frames will be evicted from the cache.
