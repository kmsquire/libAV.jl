using Test
using ColorTypes: RGB, Gray, N0f8, red, green, blue
import ColorVectorSpace
using FileIO, ImageCore, Dates, Statistics
using Statistics, StatsBase

import FFMPEG

import VideoIO

testdir = dirname(@__FILE__)
videodir = joinpath(testdir, "..", "videos")

VideoIO.TestVideos.available()
VideoIO.TestVideos.download_all()

swapext(f, new_ext) = "$(splitext(f)[1])$new_ext"

isarm() = Base.Sys.ARCH in (:arm,:arm32,:arm7l,:armv7l,:arm8l,:armv8l,:aarch64,:arm64)

#@show Base.Sys.ARCH

@noinline function isblank(img)
    all(c->green(c) == 0, img) || all(c->blue(c) == 0, img) || all(c->red(c) == 0, img) || maximum(rawview(channelview(img))) < 0xcf
end

function compare_colors(a::RGB, b::RGB, tol)
    ok = true
    for f in (red, green, blue)
        ok &= abs(float(f(a)) - float(f(b))) <= tol
    end
    ok
end

# Helper functions
function test_compare_frames(test_frame, ref_frame, tol = 0.05)
    if isarm()
        @test_skip test_frame == ref_frame
    else
        frames_similar = true
        for (a, b) in zip(test_frame, ref_frame)
            frames_similar &= compare_colors(a, b, tol)
        end
        @test frames_similar
    end
end

# uses read!
function get_first_frame!(img, v)
    seekstart(v)
    read!(v, img)
    while isblank(img)
        read!(v, img)
    end
end

function make_comparison_frame_png(vidpath::AbstractString, frameno::Integer,
                                   writedir = tempdir())
    vid_basename = first(splitext(basename(vidpath)))
    png_name = joinpath(writedir, "$(vid_basename)_$(frameno).png")
    FFMPEG.exe(`-y -v error -i $(vidpath) -vf "select=eq(n\,$(frameno-1))" -vframes 1 $(png_name)`)
    png_name
end

function make_comparison_frame_png(f, args...)
    png_name = make_comparison_frame_png(args...)
    try
        f(png_name)
    finally
        rm(png_name, force = true)
    end
end

include("avptr.jl")

testvidpath = "testvideo.mp4"

const required_accuracy = 0.07
@testset "Reading of various example file formats" begin
    for testvid in values(VideoIO.TestVideos.videofiles)
        name = testvid.name
        test_frameno = testvid.testframe
        @testset "Reading $(testvid.name)" begin
            testvid_path = joinpath(@__DIR__, "../videos", name)
            first_frame = make_comparison_frame_png(load, testvid_path, test_frameno)

            f = VideoIO.testvideo(testvid_path)
            v = VideoIO.openvideo(f)

            time_seconds = VideoIO.gettime(v)
            @test time_seconds == 0
            width, height = VideoIO.out_frame_size(v)
            if size(first_frame, 1) > height
                first_frame = first_frame[1+size(first_frame,1)-height:end,:]
            end

            # Find the first non-trivial image
            img = read(v)
            i=1
            while i < test_frameno
                read!(v, img)
                i += 1
            end
            test_compare_frames(img, first_frame, required_accuracy)

            for i in 1:50
                read!(v,img)
            end
            fiftieth_frame = img
            fiftytime = VideoIO.gettime(v)

            while !eof(v)
                read!(v, img)
            end

            seek(v,fiftytime)
            read!(v,img)

            @test img == fiftieth_frame

            seekstart(v)
            buff, align = VideoIO.read_raw(v, 1)
            @test align == 1
            buff_bak = copy(buff)
            seekstart(v)
            VideoIO.read_raw!(v, buff, 1)
            @test buff == buff_bak
            v_raw = VideoIO.openvideo(testvid_path, transcode = false)
            notranscode_buff = read(v_raw)
            @test notranscode_buff == buff_bak



            # read first frames again, and compare
            get_first_frame!(img, v)
            test_compare_frames(img, first_frame, required_accuracy)

            # make sure read! works with both PermutedDimsArray and Array
            # The above tests already use read! for PermutedDimsArray, so just test the type of img
            @test typeof(img) <: PermutedDimsArray

            img_p = parent(img)
            @assert typeof(img_p) <: Array
            # img is a view of img_p, so calling read! on img_p should alter img
            #
            # first, zero img out to be sure we get the desired result from calls to read on img_p!
            fill!(img, zero(eltype(img)))
            # Then get the first frame, which uses read!
            get_first_frame!(img_p, v)
            # Finally compare the result to make sure it's right
            test_compare_frames(img, first_frame, required_accuracy)

            # Skipping & frame counting
            VideoIO.seekstart(v)
            VideoIO.skipframe(v)
            VideoIO.skipframes(v, 10)
            @test VideoIO.counttotalframes(v) == VideoIO.TestVideos.videofiles[name].numframes

            close(v)
        end
    end
end

@testset "IO reading of various example file formats" begin
    for testvid in values(VideoIO.TestVideos.videofiles)
        name = testvid.name
        test_frameno = testvid.testframe
        # TODO: fix me?
        (startswith(name, "ladybird") || startswith(name, "NPS")) && continue
        @testset "Testing $name" begin
            testvid_path = joinpath(@__DIR__, "../videos", name)
            first_frame = make_comparison_frame_png(load, testvid_path, test_frameno)

            filename = joinpath(videodir, name)
            v = VideoIO.openvideo(VideoIO.open(filename))

            width, height = VideoIO.out_frame_size(v)
            if size(first_frame, 1) > height
                first_frame = first_frame[1+size(first_frame,1)-height:end,:]
            end
            img = read(v)
            i=1
            while i < test_frameno
                read!(v, img)
                i += 1
            end
            test_compare_frames(img, first_frame, required_accuracy)
            while !eof(v)
                read!(v, img)
            end

            # Iterator interface
            VT = typeof(v)
            @test Base.IteratorSize(VT) === Base.SizeUnknown()
            @test Base.IteratorEltype(VT) === Base.EltypeUnknown()

            VideoIO.seekstart(v)
            i = 0
            local first_frame
            local last_frame
            for frame in v
                i += 1
                if i == 1
                    first_frame = frame
                end
                last_frame = frame
            end
            @test i == VideoIO.TestVideos.videofiles[name].numframes
            # test that the frames returned by the iterator have distinct storage
            if i > 1
                @test first_frame !== last_frame
            end

            ## Test that iterator is mutable, and continues where iteration last
            ## stopped.
            @test iterate(v) === nothing
        end
    end

    VideoIO.testvideo("ladybird") # coverage testing
    @test_throws ErrorException VideoIO.testvideo("rickroll")
    @test_throws ErrorException VideoIO.testvideo("")
end

@testset "Reading video metadata" begin
    @testset "Reading Storage Aspect Ratio: SAR" begin
        # currently, the SAR of all the test videos is 1, we should get another video with a valid SAR that is not equal to 1
        vids = Dict("ladybird.mp4" => 1, "black_hole.webm" => 1, "crescent-moon.ogv" => 1, "annie_oakley.ogg" => 1)
        @test all(VideoIO.aspect_ratio(VideoIO.openvideo(joinpath(videodir, k))) == v for (k,v) in vids)
    end
    @testset "Reading video duration, start date, and duration" begin
        # tesing the duration and date & time functions:
        file = joinpath(videodir, "annie_oakley.ogg")
        @test VideoIO.get_duration(file) == 24224200/1e6
        @test VideoIO.get_start_time(file) == DateTime(1970, 1, 1)
        @test VideoIO.get_time_duration(file) == (DateTime(1970, 1, 1), 24224200/1e6)
        @test VideoIO.get_number_frames(file) === nothing
    end
    @testset "Reading the number of frames from container" begin
        file = joinpath(videodir, "ladybird.mp4")
        @test VideoIO.get_number_frames(file) == 398
        @test VideoIO.get_number_frames(file, 0) == 398
        @test_throws ArgumentError VideoIO.get_number_frames(file, -1)
        @test_throws ErrorException VideoIO.get_number_frames("Not_a_file")
    end
end


@testset "Encoding video across all supported colortypes" begin
    for el in [UInt8, RGB{N0f8}]
        @testset "Encoding $el imagestack" begin
            n = 100
            imgstack = map(x->rand(el,100,100),1:n)
            props = [:priv_data => ("crf"=>"23", "preset"=>"medium")]
            VideoIO.encodevideo(testvidpath, imgstack,
                                                   framerate=30,
                                                   AVCodecContextProperties=props,
                                                   silent=true)
            @test stat(testvidpath).size > 100
            f = VideoIO.openvideo(testvidpath)
            @test_broken VideoIO.counttotalframes(f) == n # missing frames due to edit list bug?
            close(f)
        end
    end
end

@testset "Simultaneous encoding and muxing" begin
    n = 100
    encoder_settings = (color_range = 2,)
    container_private_settings = (movflags = "+write_colr",)
    for el in [Gray{N0f8}, Gray{N6f10}, RGB{N0f8}, RGB{N6f10}]
        for scanline_arg in [true, false]
            @testset "Encoding $el imagestack, scanline_major = $scanline_arg" begin
                img_stack = map(x -> rand(el, 100, 100), 1 : n)
                lossless = el <: Gray
                crf = lossless ? 0 : 23
                encoder_private_settings = (crf = crf, preset = "medium")
                VideoIO.encode_mux_video(testvidpath,
                                         img_stack;
                                         encoder_private_settings =
                                         encoder_private_settings,
                                         encoder_settings = encoder_settings,
                                         container_private_settings =
                                         container_private_settings,
                                         scanline_major = scanline_arg)
                @test stat(testvidpath).size > 100
                f = VideoIO.openvideo(testvidpath, target_format =
                                      VideoIO.get_transfer_pix_fmt(el))
                if lossless
                    notempty = !eof(f)
                    @test notempty
                    if notempty
                        img = read(f)
                        test_img = scanline_arg ? parent(img) : img
                        i = 1
                        if el == Gray{N0f8}
                            @test test_img == img_stack[i]
                        else
                            @test_broken test_img == img_stack[i]
                        end
                        while !eof(f) && i < n
                            read!(f, img)
                            i += 1
                            if el == Gray{N0f8}
                                @test test_img == img_stack[i]
                            else
                                @test_broken test_img == img_stack[i]
                            end
                        end
                        @test i == n
                    end
                else
                    @test VideoIO.counttotalframes(f) == n
                end
                close(f)
            end
        end
    end
end

@testset "Encoding video with rational frame rates" begin
    n = 100
    fr = 59 // 2 # 29.5
    target_dur = 3.39
    @testset "Encoding with frame rate $(float(fr))" begin
        imgstack = map(x->rand(UInt8,100,100),1:n)
        props = [:priv_data => ("crf"=>"22","preset"=>"medium")]
        VideoIO.encodevideo(testvidpath, imgstack, framerate=fr,
                            AVCodecContextProperties = props, silent=true)
        @test stat(testvidpath).size > 100
        measured_dur_str = VideoIO.FFMPEG.exe(`-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $(testvidpath)`, command = VideoIO.FFMPEG.ffprobe, collect = true)
        @test parse(Float64, measured_dur_str[1]) == target_dur
    end
end

@testset "Encoding video with float frame rates" begin
    n = 100
    fr = 29.5 # 59 // 2
    target_dur = 3.39
    @testset "Encoding with frame rate $(float(fr))" begin
        imgstack = map(x->rand(UInt8,100,100),1:n)
        props = [:priv_data => ("crf"=>"22","preset"=>"medium")]
        VideoIO.encodevideo(testvidpath,imgstack,
                                               framerate=fr,
                                               AVCodecContextProperties=props,
                                               silent=true)
        @test stat(testvidpath).size > 100
        measured_dur_str = VideoIO.FFMPEG.exe(`-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $(testvidpath)`, command = VideoIO.FFMPEG.ffprobe, collect = true)
        @test parse(Float64, measured_dur_str[1]) == target_dur
    end
end

@testset "Video encode/decode accuracy (read, encode, read, compare)" begin
    file = joinpath(videodir, "annie_oakley.ogg")
    f = VideoIO.openvideo(file)
    imgstack_rgb = []
    imgstack_gray = []
    while !eof(f)
        img = collect(read(f))
        img_gray = convert(Array{Gray{N0f8}},img)
        push!(imgstack_rgb,img)
        push!(imgstack_gray,img_gray)
    end
    @testset "Lossless Grayscale encoding" begin
        file_lossless_gray_copy = joinpath(videodir, "annie_oakley_lossless_gray.mp4")
        prop = [:color_range=>2, :priv_data => ("crf"=>"0","preset"=>"medium")]
        codec_name="libx264"
        VideoIO.encodevideo(file_lossless_gray_copy,imgstack_gray,codec_name=codec_name,AVCodecContextProperties=prop, silent=true)

        fcopy = VideoIO.openvideo(file_lossless_gray_copy,target_format=VideoIO.AV_PIX_FMT_GRAY8)
        imgstack_gray_copy = []
        while !eof(fcopy)
            push!(imgstack_gray_copy,collect(read(fcopy)))
        end
        close(f)
        @test eltype(imgstack_gray) == eltype(imgstack_gray_copy)
        @test length(imgstack_gray) == length(imgstack_gray_copy)
        @test size(imgstack_gray[1]) == size(imgstack_gray_copy[1])
        @test !any(.!(imgstack_gray .== imgstack_gray_copy))
    end

    @testset "Lossless RGB encoding" begin
        file_lossless_rgb_copy = joinpath(videodir, "annie_oakley_lossless_rgb.mp4")
        prop = [:priv_data => ("crf"=>"0","preset"=>"medium")]
        codec_name="libx264rgb"
        VideoIO.encodevideo(file_lossless_rgb_copy,imgstack_rgb,codec_name=codec_name,AVCodecContextProperties=prop, silent=true)

        fcopy = VideoIO.openvideo(file_lossless_rgb_copy)
        imgstack_rgb_copy = []
        while !eof(fcopy)
            img = collect(read(fcopy))
            push!(imgstack_rgb_copy,img)
        end
        close(f)
        @test eltype(imgstack_rgb) == eltype(imgstack_rgb_copy)
        @test length(imgstack_rgb) == length(imgstack_rgb_copy)
        @test size(imgstack_rgb[1]) == size(imgstack_rgb_copy[1])
        @test !any(.!(imgstack_rgb .== imgstack_rgb_copy))
    end

    @testset "UInt8 accuracy during read & lossless encode" begin
        # Test that reading truth video has one of each UInt8 value pixels (16x16 frames = 256 pixels)
        f = VideoIO.openvideo(joinpath(testdir,"precisiontest_gray_truth.mp4"),target_format=VideoIO.AV_PIX_FMT_GRAY8)
        frame_truth = collect(rawview(channelview(read(f))))
        h_truth = fit(Histogram, frame_truth[:], 0:256)
        @test h_truth.weights == fill(1,256) #Test that reading is precise

        # Test that encoding new test video has one of each UInt8 value pixels (16x16 frames = 256 pixels)
        img = Array{UInt8}(undef,16,16)
        for i in 1:256
            img[i] = UInt8(i-1)
        end
        imgstack = []
        for i=1:24
            push!(imgstack,img)
        end
        props = [:color_range=>2, :priv_data => ("crf"=>"0","preset"=>"medium")]
        VideoIO.encodevideo(joinpath(testdir,"precisiontest_gray_test.mp4"), imgstack,
            AVCodecContextProperties = props,silent=true)
        f = VideoIO.openvideo(joinpath(testdir,"precisiontest_gray_test.mp4"),
            target_format=VideoIO.AV_PIX_FMT_GRAY8)
        frame_test = collect(rawview(channelview(read(f))))
        h_test = fit(Histogram, frame_test[:], 0:256)
        @test h_test.weights == fill(1,256) #Test that encoding is precise (if above passes)

        @test VideoIO.counttotalframes(f) == 24
    end

    @testset "Correct frame order when reading & encoding" begin
        @testset "Frame order when reading ground truth video" begin
            # Test that reading a video with frame-incremental pixel values is read in in-order
            f = VideoIO.openvideo(joinpath(testdir,"ordertest_gray_truth.mp4"),target_format=VideoIO.AV_PIX_FMT_GRAY8)
            frame_ids_truth = []
            while !eof(f)
                img = collect(rawview(channelview(read(f))))
                push!(frame_ids_truth,img[1,1])
            end
            @test frame_ids_truth == collect(0:255) #Test that reading is in correct frame order
            @test VideoIO.counttotalframes(f) == 256
        end
        @testset "Frame order when encoding, then reading video" begin
            # Test that writing and reading a video with frame-incremental pixel values is read in in-order
            imgstack = []
            img = Array{UInt8}(undef,16,16)
            for i in 0:255
                push!(imgstack,fill(UInt8(i),(16,16)))
            end
            props = [:color_range=>2, :priv_data => ("crf"=>"0","preset"=>"medium")]
            VideoIO.encodevideo(joinpath(testdir,"ordertest_gray_test.mp4"), imgstack,
                AVCodecContextProperties = props,silent=true)
            f = VideoIO.openvideo(joinpath(testdir,"ordertest_gray_test.mp4"),
                target_format=VideoIO.AV_PIX_FMT_GRAY8)
            frame_ids_test = []
            while !eof(f)
                img = collect(rawview(channelview(read(f))))
                push!(frame_ids_test,img[1,1])
            end
            @test frame_ids_test == collect(0:255) #Test that reading is in correct frame order
            @test VideoIO.counttotalframes(f) == 256
        end
    end
end

rm(testvidpath, force = true)

@testset "c api memory leak test" begin # Issue https://github.com/JuliaIO/VideoIO.jl/issues/246

    if(Sys.islinux())  # TODO: find a method to get cross platform memory usage, see: https://discourse.julialang.org/t/how-to-get-current-julia-process-memory-usage/41734/4

        function get_memory_usage()
            open("/proc/$(getpid())/statm") do io
                split(read(io, String))[1]
            end
        end

        file = joinpath(videodir, "annie_oakley.ogg")

        @testset "open file test" begin
            check_size = 10
            usage_vec = Vector{String}(undef, check_size)

            for i in 1:check_size

                f = VideoIO.openvideo(file)
                close(f)
                GC.gc()

                usage_vec[i] = get_memory_usage()
            end

            println(usage_vec)

            @test usage_vec[end-1] == usage_vec[end]
        end

        @testset "open and read file test" begin
            check_size = 10
            usage_vec = Vector{String}(undef, check_size)

            for i in 1:check_size

                f = VideoIO.openvideo(file)
                img = read(f)
                close(f)
                GC.gc()

                usage_vec[i] = get_memory_usage()
            end

            println(usage_vec)

            @test usage_vec[end-1] == usage_vec[end]
        end
    end
end



#VideoIO.TestVideos.remove_all()
