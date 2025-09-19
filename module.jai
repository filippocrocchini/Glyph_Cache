
init_font_cache :: (width: s32, height: s32)
{
    if cache.initialized return;

    FT_Init_FreeType(*freetype);

    reset_page(*cache.page, width, height);

    cache.initialized = true;
}

deinit_font_cache :: ()
{
    free(cache.page.bitmap.pixels.data,, cache.page.allocator);
    deinit(*cache.glyphs_in_atlas);
    FT_Done_FreeType(freetype);
}

set_page_size :: (width: int, height: int)
{
    reset_page(*cache.page, width, height);
}

add_font_from_memory :: (memory: []u8) -> bool
{
    args := FT_Open_Args.{};
    args.memory_base = cast(*FT_Byte) memory.data;
    args.memory_size = cast(FT_Long)  memory.count;
    args.flags       = FT_OPEN_MEMORY;
    
    face_count := 0;
    
    {
        tmp_face : FT_Face = null;
        error    := FT_Open_Face(freetype, *args, -1, *tmp_face);
        defer FT_Done_Face(tmp_face);
        
        if error return false;
        
        face_count = tmp_face.num_faces;  
    }
    
    for 0..face_count-1
    {
        face  := array_add(*cache.loaded_faces);
        error := FT_Open_Face(freetype, *args, cast(FT_Long) it, face);
        
        if error return false;
    }
    
    return true;
}

add_font_from_file :: (file_name: string) -> bool
{
    #import "File";
    
    file_content, success := read_entire_file(file_name);
    
    if !success return false;
    
    return add_font_from_memory(xx file_content);
}

// This is by far not the best way to do this but it works for now.
// I don't really know a good way of implementing a generic interface.
// Some fonts are variable and support a "weight" from 0 to 1000, some
// have a BOLD/NORMAL flag, some have the weight as text in the family
// name and some require you to specify that yourself.
// Meh.
//
// Also, variable fonts. Not supported.
// 
// I considered requiring a weight parameter to add_font_from_xxx()
// but, since you could be adding collections, I don't know how that would
// work.
// 
// -Filippo
 
find_best_face_for_style :: (style: Style_Description) -> Font_Face
{
    assert(cache.loaded_faces.count != 0, "There are no faces loaded.");
    
    result     : u64 = 0;
    best_score : int = 0;
    
    for cache.loaded_faces
    {
        score := 0;

        family_name := to_string(it.family_name);
        style_name  := to_string(it.style_name);
        
        if equal_nocase(family_name, style.family)
        {
            score += 1000;
        }
        
        if it.style_flags & FT_STYLE_FLAG_BOLD && style.weight == .BOLD
        {
            score += 50;
        }
        
        if it.style_flags & FT_STYLE_FLAG_ITALIC && style.style == .ITALIC
        {
            score += 50;
        }
        
        if contains_nocase(style_name, font_weight_string(style.weight))
        {
            score += 50;
        }

        if contains_nocase(style_name, font_style_string(style.style))
        {
            score += 50;
        }
        
        if score > best_score
        {
            result     = xx it_index;
            best_score = score;
        }
    }
    
    return Font_Face.{ result };
}

get_freetype_face :: (face: Font_Face) -> FT_Face
{
    return cache.loaded_faces[face.index];
}

get_access_timestamp :: () -> u32
{
    return cache.access_timestamp;
}

peek_cache_bitmap :: (evict_after: u64) -> dirty : bool, bitmap : Bitmap
{
    cache.access_timestamp += 1;

    if !cache.page.dirty
    {
        evict_outdated_entries(evict_after);
        return false, .{};
    }

    cache.page.dirty = false;

    return true, cache.page.bitmap;
}

bind_face :: (face: Font_Face, pixels_per_em: u32)
{
    ft_face := get_freetype_face(face);
    FT_Set_Pixel_Sizes(ft_face, 0, pixels_per_em);

    cache.currently_bound_face = face;
    cache.currently_bound_pixels_per_em = pixels_per_em;
}

get_glyph_for_codepoint :: (codepoint: u32, padding := 1, padding_clamp_to_edge := false) -> glyph: Cached_Glyph, success: bool
{
    ft_face     := get_freetype_face(cache.currently_bound_face);
    glyph_index := FT_Get_Char_Index(ft_face, codepoint);

	glyph, success := get_glyph(glyph_index, padding, padding_clamp_to_edge);

    return glyph, success;
}

get_glyph :: (glyph_index: u32, padding := 1, padding_clamp_to_edge := false) -> glyph: Cached_Glyph, success: bool
{
    ft_face := get_freetype_face(cache.currently_bound_face);

    // Here we are using the index instead of the codepoint because we want all missing codepoints to
    // map to the same "missing" glyph.
    hash := get_hash(cache.currently_bound_face.index, glyph_index, cache.currently_bound_pixels_per_em); 
    
    entry := table_find_pointer(*cache.glyphs_in_atlas, hash);

    if entry
    {
        cache.debug_hits_count += 1;
        entry.last_access      = cache.access_timestamp;

        return <<entry, true;
    }

    antialiasing := true;
    flags := cast(s32) FT_LOAD_FORCE_AUTOHINT;
    if antialiasing
    {
        flags |= cast(s32) FT_Render_Mode_.NORMAL;
    } else 
    {
        flags |= cast(s32) FT_Render_Mode_.MONO;
    }

    if FT_HAS_COLOR(ft_face)
        flags |= cast(s32) FT_LOAD_COLOR;
    else
        flags |= cast(s32) FT_LOAD_RENDER;     

    error_loading_glyph := FT_Load_Glyph(ft_face, glyph_index, flags);

    if error_loading_glyph
    {
        return Cached_Glyph.{}, false;
    }

    glyph_size    := int.[ft_face.glyph.bitmap.width,    ft_face.glyph.bitmap.rows];
    glyph_bearing := int.[ft_face.glyph.bitmap_left,     ft_face.glyph.bitmap_top];
    glyph_advance := int.[ft_face.glyph.advance.x >> 6,  ft_face.glyph.advance.y >> 6];

    if glyph_size[0] == 0 || glyph_size[1] == 0
    {
        // There's nothing to draw, the glyph has no area.
        // (but we still keep the size?)
        return Cached_Glyph.{
                x = 0,
                y = 0,
                w = glyph_size[0],
                h = glyph_size[1],

                bearing_x = glyph_bearing[0],
                bearing_y = glyph_bearing[1],

                advance_x = glyph_advance[0],
                advance_y = glyph_advance[1],
                
                packed_rect = null,
                last_access = 0
            },
            true;
    }

    cache.debug_misses_count += 1;

    packed_rect := Rect_Pack.rect_packer_add(*cache.page.packer, glyph_size[0] + 2 * padding, glyph_size[1] + 2 * padding);
    
    if !packed_rect
    {
        cache.debug_failures_count += 1;

        return Cached_Glyph.{
                x = 0,
                y = 0,
                w = glyph_size[0],
                h = glyph_size[1],

                bearing_x = glyph_bearing[0],
                bearing_y = glyph_bearing[1],

                advance_x = glyph_advance[0],
                advance_y = glyph_advance[1],
                
                packed_rect = null,
                last_access = 0
            },
            false;
    }

    error_rendering_glyph := FT_Render_Glyph(ft_face.glyph, .NORMAL);

    if error_rendering_glyph
    {
        return Cached_Glyph.{
                x = 0,
                y = 0,
                w = glyph_size[0],
                h = glyph_size[1],

                bearing_x = glyph_bearing[0],
                bearing_y = glyph_bearing[1],

                advance_x = glyph_advance[0],
                advance_y = glyph_advance[1],
                
                packed_rect = packed_rect,
                last_access = cache.access_timestamp
            },
            false;

    }

    cache.page.dirty = true;

    dst_stride := 4; // 4 channels
    dst_pitch  := cache.page.bitmap.width * dst_stride;
    dst_buffer := cache.page.bitmap.pixels.data + (packed_rect.y + padding) * dst_pitch + (packed_rect.x + padding) * dst_stride;

    bitmap     := *ft_face.glyph.bitmap;

    src_buffer := bitmap.buffer;
    src_width  := bitmap.width;
    src_height := bitmap.rows;
    src_pitch  := bitmap.pitch;

    src                := src_buffer;
    first_pixel_in_row := src;

    for y: 0..src_height-1
    {
        src = first_pixel_in_row;

        for x: 0..src_width-1
        {
            if cast(FT_Pixel_Mode) bitmap.pixel_mode == 
            {
                case .MONO;
                    value := <<src;
        
                    dst := y * dst_pitch + (x * 8) * dst_stride;

                    for i: 0..7
                    {
                        dst_buffer[dst]   = 0xff;
                        dst_buffer[dst+1] = 0xff;
                        dst_buffer[dst+2] = 0xff;
                        dst_buffer[dst+3] = cast(u8) ifx value & (0b10000000 >> i) then 255 else 0;
                    }
        
                    src += 1;

                case .BGRA;
                    b := << (src + 0);
                    g := << (src + 1);
                    r := << (src + 2);
                    a := << (src + 3);
        
                    dst := y * dst_pitch + x * dst_stride;

                    dst_buffer[dst + 0] = b;
                    dst_buffer[dst + 1] = g;
                    dst_buffer[dst + 2] = r;
                    dst_buffer[dst + 3] = a;

                    src += 4;
                case .GRAY;
                    value := <<src;
        
                    dst := y * dst_pitch + x * dst_stride;

                    dst_buffer[dst]   = 0xff;  // +0 == B
                    dst_buffer[dst+1] = 0xff;  // +1 == G
                    dst_buffer[dst+2] = 0xff;  // +2 == R
                    dst_buffer[dst+3] = value; // +3 == A

                    src += 1;
                case;
                    assert(false, "Unhandled bitmap format.");
            }
        }

        first_pixel_in_row += src_pitch;
    }

    if padding_clamp_to_edge {
        // Fill border

        for 0..padding - 1
        {
            memcpy(
                cache.page.bitmap.pixels.data + (packed_rect.y + it) * dst_pitch + packed_rect.x * dst_stride,
                cache.page.bitmap.pixels.data + (packed_rect.y + padding) * dst_pitch + packed_rect.x * dst_stride,
                dst_stride * (bitmap.width + 2*padding)
                );

            memcpy(
                cache.page.bitmap.pixels.data + (packed_rect.y + bitmap.rows + it + padding) * dst_pitch + packed_rect.x * dst_stride,
                cache.page.bitmap.pixels.data + (packed_rect.y + bitmap.rows + padding) * dst_pitch + packed_rect.x * dst_stride,
                dst_stride * (bitmap.width + 2*padding)
                );
        }   

        for 0..bitmap.rows-1
        {
            row_start := cache.page.bitmap.pixels.data + (packed_rect.y + it + padding) * dst_pitch + packed_rect.x * dst_stride;

            for 0..padding-1
            {
                memcpy(
                    row_start + it * dst_stride,
                    row_start + padding * dst_stride,
                    dst_stride
                    );
            }

            for 0..padding-1
            {
                memcpy(
                    row_start + (bitmap.width + padding + it) * dst_stride,
                    row_start + (bitmap.width + padding - 1)  * dst_stride,
                    dst_stride
                    );
            }
        }
    }
    else 
    {
        for 0..padding - 1
        {
            row_start := cache.page.bitmap.pixels.data + (packed_rect.y + it) * dst_pitch + packed_rect.x * dst_stride;
            memset(row_start, 0, dst_stride * (bitmap.width + 2*padding));
        }

        for 0..bitmap.rows-1
        {
            row_start := cache.page.bitmap.pixels.data + (packed_rect.y + padding + it) * dst_pitch + packed_rect.x * dst_stride;

            memset(row_start, 0, padding * dst_stride);
            memset(row_start + (bitmap.width + padding) * dst_stride, 0, padding * dst_stride);
        }

        for 0..padding - 1 
        {
            row_start := cache.page.bitmap.pixels.data + (packed_rect.y + padding + bitmap.rows + it) * dst_pitch + packed_rect.x * dst_stride;
            memset(row_start, 0, dst_stride * (bitmap.width + 2*padding));
        }
    }


    result := Cached_Glyph.{
            x = packed_rect.x + padding,
            y = packed_rect.y + padding,
            w = bitmap.width,
            h = bitmap.rows,

            bearing_x = glyph_bearing[0],
            bearing_y = glyph_bearing[1],

            advance_x = glyph_advance[0],
            advance_y = glyph_advance[1],
            
            packed_rect = packed_rect,
            last_access = cache.access_timestamp
        };

    table_add(*cache.glyphs_in_atlas, hash, result);

    // log("Added a new glyph to the table at %. Count is now: %\n", cache.access_timestamp, cache.glyphs_in_atlas.count);

    return result, true;
}

Font_Face :: struct 
{
    index: u64;
}

Font_Style :: enum 
{
    NORMAL :: 0;

    ITALIC;
    OBLIQUE;
}

Font_Weight :: enum 
{
    NORMAL :: 0;

    THIN;
    EXTRA_LIGHT;
    LIGHT;
    MEDIUM;
    SEMI_BOLD;
    BOLD;
    EXTRA_BOLD;
    BLACK;
}

Style_Description :: struct 
{
    family : string;
    style  : Font_Style  = .NORMAL;    
    weight : Font_Weight = .NORMAL;
}

Cached_Glyph :: struct
{
    x, y: int;
    w, h: int;

    bearing_x, bearing_y : int;
    advance_x, advance_y : int;

    // Internal
    packed_rect: *Rect_Pack.Rect;
    last_access: u32;
}

Bitmap :: struct
{
    pixels : []u8;
    width  : s32;
    height : s32;
}

#scope_module

font_style_string :: (style: Font_Style) -> string 
{
    if #complete style == 
    {
        case .NORMAL;  return "regular";
        case .ITALIC;  return "italic";
        case .OBLIQUE; return "oblique";
    }
}

font_weight_string :: (weight: Font_Weight) -> string 
{
    if #complete weight == 
    {
        case .NORMAL;      return "normal";
        case .THIN;        return "thin";
        case .EXTRA_LIGHT; return "extralight";
        case .LIGHT;       return "light";
        case .MEDIUM;      return "medium";
        case .SEMI_BOLD;   return "semibold";
        case .BOLD;        return "bold";
        case .EXTRA_BOLD;  return "extrabold";
        case .BLACK;       return "black";
    }
}

reset_page :: (page: *Page, width: s32, height: s32) 
{
    if page.bitmap.pixels.data
    {
        free(page.bitmap.pixels.data,, page.allocator);
        <<page = .{};
    }
    
    remember_allocators(page);

    Rect_Pack.rect_packer_init(
        *page.packer,
        width,
        height,
        .GUILLOTINE_SLAB_SIZE,
        .BOTTOM_LEFT
    );
    
    PIXEL_COMPONENTS :: 4;
    
    page.bitmap.pixels = NewArray(width * height * PIXEL_COMPONENTS, u8,, page.allocator);
    page.bitmap.width  = width;
    page.bitmap.height = height;
}

evict_outdated_entries :: (evict_after: u64)
{
	for * cache.glyphs_in_atlas
	{
		if cache.access_timestamp >= evict_after + it.last_access
		{

            // log("Evicting glyph after %\n", cache.access_timestamp - it.last_access);

			Rect_Pack.rect_packer_remove(*cache.page.packer, it.packed_rect);
			remove it;

			cache.debug_eviction_count += 1;
		}
	}
}
    
get_hash :: (face_index: u64, glyph_index: u64, pixels_per_em: u64) -> u64
{
    Hash :: #import "Hash";

    data := u64.[face_index, glyph_index, pixels_per_em];

    result := Hash.fnv1a_hash(data.data, data.count * size_of(u64));

    return result;
}

cache    : Cache;
freetype : FT_Library;

Page :: struct 
{
    packer    : Rect_Pack.Rect_Packer;
    dirty     : bool;
    bitmap    : Bitmap;
    allocator : Allocator;
}

Cache :: struct
{
    loaded_faces : [..]FT_Face;
    
    currently_bound_face: Font_Face;
    currently_bound_pixels_per_em: u32;

    page : Page; // Have more for overflow

    glyphs_in_atlas : Table(u64, Cached_Glyph);

    access_timestamp: u32;
    initialized     : bool;

    debug_hits_count     : int;
    debug_misses_count   : int;
    debug_eviction_count : int;
    debug_failures_count : int;
}

Rect_Pack :: #import "Rect_Pack";
#import "freetype-2.12.1";
#import "Hash_Table";
#import "String";
#import "Basic";