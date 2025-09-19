#import "Window_Creation";
#import "System";
#import "Math";
#import "Basic";
#import "Input";

Simp       :: #import "Simp";
Glyph_Cache :: #import, file "../module.jai";

glyph_cache_texture : Simp.Texture;

Glyph_Node :: struct 
{
    position_min: Vector2;
    size: Vector2;

    color: Vector4;

    texture: *Simp.Texture;
    texture_min: Vector2;
    texture_size: Vector2;
}

Glyph_Node_Slice :: struct 
{
    first, last: int;
}

prepared_nodes : [..]Glyph_Node;

commit_prepared_nodes :: ()
{
    for * prepared_nodes
    {
        it.position_min.x = floor(it.position_min.x);
        it.position_min.y = floor(it.position_min.y);
        // it.position_max.x = floor(it.position_max.x);
        // it.position_max.y = floor(it.position_max.y);

        x0 := it.position_min.x;
        x1 := it.position_min.x + it.size.x;
        y0 := it.position_min.y;
        y1 := it.position_min.y + it.size.y;

        s0 := it.texture_min.x;
        s1 := it.texture_min.x + it.texture_size.x;
        t0 := it.texture_min.y;
        t1 := it.texture_min.y + it.texture_size.y;

        p1 := Vector2.{ xx x0, xx y0 };
        u1 := Vector2.{s0, t0};

        p2 := Vector2.{ xx x0, xx y1 };
        u2 := Vector2.{s0, t1};

        p3 := Vector2.{ xx x1, xx y1 };
        u3 := Vector2.{s1, t1};

        p4 := Vector2.{ xx x1, xx y0 };
        u4 := Vector2.{s1, t0};

        Simp.set_shader_for_images(it.texture);
        Simp.immediate_quad(p1, p2, p3, p4, it.color, u1, u2, u3, u4);
    }
}

reset_prepared_nodes :: ()
{
    array_reset(*prepared_nodes);
}

for_expansion :: (slice: Glyph_Node_Slice, body: Code, flags: For_Flags) #expand {
    for index: slice.first..slice.last
    {  
        `it_index := index - slice.first;

        #if flags & .POINTER
        {
            `it := *prepared_nodes[index];
        }
        else
        {
            `it := prepared_nodes[index];
        }

        #insert body;
    }
}

draw_text :: (text: string, font: Glyph_Cache.Font_Face, pixels_per_em: u32, position: Vector2 = .{}, color: Vector4 = .{1, 1, 1, 1}) -> Glyph_Node_Slice
{
    #import "Unicode";

    Glyph_Cache.bind_face(font, pixels_per_em);

    cursor_x : float = position.x;
    cursor_y : float = position.y;

    prepared_nodes_count := prepared_nodes.count;

    remaining := text;
    while remaining.count
    {
        codepoint, success := utf8_next_character(*remaining);

        if success != .CONVERSION_OK break;

        glyph, found := Glyph_Cache.get_glyph_for_codepoint(codepoint);

		baseline_origin := Vector2.{ cursor_x, cursor_y };

        x0 := baseline_origin.x + glyph.bearing_x;
        y0 := baseline_origin.y - glyph.bearing_y;

        node := array_add(*prepared_nodes);

        node.position_min.x = x0;
        node.position_min.y = y0;
        node.size.x = cast(float) glyph.w;
        node.size.y = cast(float) glyph.h;

        // print("%\n", glyph.h);

        s0_px := glyph.x;
        t0_px := glyph.y;

        node.texture_min.x  = s0_px / cast(float) glyph_cache_texture.width;
        node.texture_min.y  = t0_px / cast(float) glyph_cache_texture.height;
        node.texture_size.x = glyph.w / cast(float) glyph_cache_texture.width;
        node.texture_size.y = glyph.h / cast(float) glyph_cache_texture.height;

        node.color = color;

        node.texture = *glyph_cache_texture;

        cursor_x += glyph.advance_x;
        cursor_y -= glyph.advance_y;
    }

    result : Glyph_Node_Slice;
    result.first = prepared_nodes_count;
    result.last  = prepared_nodes.count - 1;

    return result;
}

draw_rect :: (position: Vector2, size: Vector2, region_min: Vector2, region_size: Vector2, color: Vector4) 
{
    p1 := position;
    p2 := position + .{ size.x, 0};
    p3 := position + size;
    p4 := position + .{ 0, size.y };
    
    u1 := region_min;
    u2 := region_min + .{ region_size.x, 0};
    u3 := region_min + region_size;
    u4 := region_min + .{ 0, region_size.y };

    Simp.immediate_quad(p1, p2, p3, p4, color, u4, u3, u2, u1);
}

get_bounds :: (nodes: Glyph_Node_Slice) -> min_pos: Vector2, max_pos: Vector2
{
    min_pos : Vector2 = .{ FLOAT32_INFINITY,  FLOAT32_INFINITY};
    max_pos : Vector2 = .{-FLOAT32_INFINITY, -FLOAT32_INFINITY};

    for * nodes
    {
        min_pos.x = min(min_pos.x, it.position_min.x);
        min_pos.x = min(min_pos.x, it.position_min.x + it.size.x);

        min_pos.y = min(min_pos.y, it.position_min.y);
        min_pos.y = min(min_pos.y, it.position_min.y + it.size.y);

        max_pos.x = max(max_pos.x, it.position_min.x);
        max_pos.x = max(max_pos.x, it.position_min.x + it.size.x);

        max_pos.y = max(max_pos.y, it.position_min.y);
        max_pos.y = max(max_pos.y, it.position_min.y + it.size.y);
    }

    return min_pos, max_pos;
}

main :: ()
{
    Glyph_Cache.init_font_cache(width = 512, height = 512);
    defer Glyph_Cache.deinit_font_cache();

    Glyph_Cache.add_font_from_file("Karla-Regular.ttf");

    font := Glyph_Cache.find_best_face_for_style(.{ family = "Karla Regular" });

    window_width  : s32 = 1080;
    window_height : s32 =  720;
    
    quit := false;
    
    window := create_window(window_width, window_height, "A Window");
    Simp.set_render_target(window, .LEFT_HANDED);
    
    while !quit
    {
        defer 
        {
            Simp.swap_buffers(window);
    
            reset_prepared_nodes();
            reset_temporary_storage();

            sleep_milliseconds(8);
        }
        
        update_window_events();
        
        for get_window_resizes()
        {
            if it.window == window
            {
                window_width  = it.width;
                window_height = it.height;
                Simp.update_window(window);
            }
        }

        for events_this_frame
        {
            if it.type == .QUIT then 
                quit = true;
        }
        
        Simp.clear_render_target(0.1, 0.1, 0.1, 1);
        Simp.set_shader_for_color(true);
        
        text_nodes := draw_text("Glyphs will be evicted from cache after 8 frames from last use.", font, cast(u32) (sin(seconds_since_init() * 4) * 10 + 20), color = .{0.8, 0.7, 0.4, 1});
        other_text_nodes := draw_text("These will never be evicted.", font, 32, color = .{0.4, 0.8, 0.4, 1});

        min_pos, max_pos := get_bounds(text_nodes);

        for * text_nodes
        {
            it.position_min += Vector2.{xx window_width, xx window_height} / 2 - (max_pos + min_pos) / 2;
        }

        min_pos, max_pos              = get_bounds(text_nodes);
        other_min_pos, other_max_pos := get_bounds(other_text_nodes);
        
        for * other_text_nodes
        {
            it.position_min.x += (min_pos.x + max_pos.x) / 2 - (other_max_pos.x - other_min_pos.x) / 2;

            it.position_min.y += max_pos.y - other_min_pos.y + 10;
        }

        Simp.set_shader_for_images(*glyph_cache_texture);
        pos := Vector2.{0, 0};

        Simp.immediate_quad(
            pos + Vector2.{},
            pos + Vector2.{xx glyph_cache_texture.width, 0},
            pos + Vector2.{xx glyph_cache_texture.width, xx glyph_cache_texture.height},
            pos + Vector2.{0, xx glyph_cache_texture.height},
            
            Vector4.{1, 1, 1, 0.4},
            
            Vector2.{0, 0},
            Vector2.{1, 0},
            Vector2.{1, 1},
            Vector2.{0, 1},
            );

        dirty, bitmap := Glyph_Cache.peek_cache_bitmap(evict_after = 8);
        if dirty
        {
            simp_bitmap : Simp.Bitmap;
            simp_bitmap.width  = bitmap.width;
            simp_bitmap.height = bitmap.height;
            simp_bitmap.stride = bitmap.width * 4;
            simp_bitmap.data   = bitmap.pixels;

            Simp.texture_load_from_bitmap(*glyph_cache_texture, *simp_bitmap);
            Simp.immediate_flush();
        }

        commit_prepared_nodes();
    }
}