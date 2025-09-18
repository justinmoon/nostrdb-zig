use std::path::PathBuf;

fn main() {
    let crate_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir"));
    let include_dir = crate_dir.join("include");
    std::fs::create_dir_all(&include_dir).expect("create include dir");
    let header_path = include_dir.join("openmls_ffi.h");

    let config_path = crate_dir.join("cbindgen.toml");

    let mut builder = cbindgen::Builder::new();
    builder = builder.with_crate(crate_dir);
    if config_path.exists() {
        builder = builder
            .with_config(cbindgen::Config::from_file(config_path).expect("load cbindgen config"));
    }

    builder
        .generate()
        .expect("generate header")
        .write_to_file(header_path);
}
