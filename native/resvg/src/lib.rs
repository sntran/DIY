//! The NIF of `DIY.Picture`: resvg 0.48.1 in WebAssembly, for beam.com
//! (docs/NIFS.md of BEAM.com). It draws an SVG to a PNG of a given width.
//!
//! The app makes the SVG from the numbers of a link, and a link can have
//! any numbers. Thus the NIF refuses a document that can use much memory
//! or much time: entities of a DTD, more than 1,048,576 pixels, and
//! images. The text uses the two fonts of `fonts/`: Inter, in its regular
//! and bold weights. The NIF reads the fonts one time, and reads no file.

use std::sync::{Arc, OnceLock};

use resvg::{tiny_skia, usvg};
use rustler::{Binary, Encoder, Env, NewBinary, Term};

mod atoms {
    rustler::atoms! { ok, error }
}

/// The pixels of the image.
const MAX_PIXELS: u64 = 1 << 20;

const REGULAR: &[u8] = include_bytes!("../fonts/Inter-Regular.otf");
const BOLD: &[u8] = include_bytes!("../fonts/Inter-Bold.otf");

/// The fonts, read at the first draw.
static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();

fn fonts() -> Arc<usvg::fontdb::Database> {
    FONTS
        .get_or_init(|| {
            let mut fontdb = usvg::fontdb::Database::new();
            fontdb.load_font_data(REGULAR.to_vec());
            fontdb.load_font_data(BOLD.to_vec());
            fontdb.set_sans_serif_family("Inter");
            Arc::new(fontdb)
        })
        .clone()
}

/// Draws the SVG `svg` at the width `width`, with the height of its
/// proportion. Gives `{:ok, png}` or `{:error, message}`.
#[rustler::nif]
fn render<'a>(env: Env<'a>, svg: Binary, width: u32) -> Term<'a> {
    match draw(svg.as_slice(), width) {
        Ok(png) => {
            let mut binary = NewBinary::new(env, png.len());
            binary.as_mut_slice().copy_from_slice(&png);
            let binary: Binary = binary.into();
            (atoms::ok(), binary).encode(env)
        }
        Err(message) => (atoms::error(), message).encode(env),
    }
}

rustler::init!("Elixir.DIY.Picture.NIF");

// The allocator of the module, for the host (docs/NIFS.md of BEAM.com).
extern "C" {
    fn malloc(size: usize) -> *mut u8;
    fn free(ptr: *mut u8);
}

#[no_mangle]
pub extern "C" fn erl_nif_wasm_malloc(size: usize) -> *mut u8 {
    unsafe { malloc(size) }
}

#[no_mangle]
pub extern "C" fn erl_nif_wasm_free(ptr: *mut u8) {
    unsafe { free(ptr) }
}

fn draw(bytes: &[u8], width: u32) -> Result<Vec<u8>, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "the SVG is not UTF-8".to_string())?;

    if text.contains("<!ENTITY") {
        return Err("entities are not supported".to_string());
    }

    let opt = usvg::Options {
        font_family: "Inter".to_string(),
        fontdb: fonts(),
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_data: Box::new(|_, _, _| None),
            resolve_string: Box::new(|_, _| None),
        },
        ..usvg::Options::default()
    };

    let tree = usvg::Tree::from_str(text, &opt).map_err(|e| e.to_string())?;
    let size = tree.size().to_int_size();

    if width == 0 {
        return Err("the width is 0".to_string());
    }

    let scale = width as f32 / size.width() as f32;
    let height = (size.height() as f32 * scale).ceil() as u32;

    if width as u64 * height as u64 > MAX_PIXELS {
        return Err(format!("the image has more than {} pixels", MAX_PIXELS));
    }

    let mut pixmap = tiny_skia::Pixmap::new(width, height).ok_or("cannot create pixmap")?;
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    pixmap.encode_png().map_err(|e| e.to_string())
}
