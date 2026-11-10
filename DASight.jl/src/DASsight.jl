"""
    DASight

Image-based machine learning for Distributed Acoustic Sensing (DAS) data:
turn DAS records into small pictures, classify them with trained ResNets
(signal vs. noise), and screen archived or live recordings.

Three steps, each with an example (see `install_examples`):

1. **PAINTER**   data → pictures        (`das2pics`)
2. **DETECTIVE** pictures → events      (`detect_files`)
3. **WATCHER**   live recording         (`watch`)

Start with `DASight.install_examples()`.
"""
module DASight

include("ImageProcessing.jl")   # data → picture
include("DataIO.jl")            # reading data files
include("ML_Handling.jl")       # picture → decision
include("Watcher.jl")           # live monitoring
include("Distribution.jl")      # models, example data, examples

# from DASVader, so users can build their own readers
export iDAS, attb

# 1. PAINTER
export empty_attb, check_das, process_das!, das2pics, save_fig, normalize_columns,
       get_dp, fkpeak, fkgaussfilter,
       auto_level_intensity, auto_level_file, batch_auto_level_intensity,
       das_image_data_augmentation, figs2dirs, noise2dirs

# getting data in
export read_das_nc, read_das_jld2

# 2. DETECTIVE
export load_model, load_detective_models, preprocess_image, list_images,
       classify_files, classify_dir, combine_predictions, detect_files,
       PipelineParams, run_pipeline, combine_scores, print_scores,
       dir_tag, write_results

# 3. WATCHER
export watch, classify_das_file, pending_files, keep_noise_file, parse_args

# models, data, examples
export models_dir, example_data_dir, install_examples

end # module
