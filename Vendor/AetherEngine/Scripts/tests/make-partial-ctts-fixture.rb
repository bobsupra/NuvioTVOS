#!/usr/bin/env ruby
# Use ONLY on the tiny generated color+tone fixture; no private media is copied to a test fixture.
# Preserve every box size and every byte outside the selected ctts offset fields.
input, output = ARGV
mode = ARGV[2] || 'tail'
first = (ARGV[3] || 240).to_i
last  = (ARGV[4] || 480).to_i
total = (ARGV[5] || 720).to_i
abort 'mode must be tail or middle' unless %w[tail middle].include?(mode)
abort 'boundaries must rise inside the track' unless 0 < first && first < last && last <= total
abort 'usage: make-partial-ctts-fixture.rb synthetic.mp4 new-output.mp4' unless input && output
abort 'output already exists' if File.exist?(output)
abort 'fixture size exceeded' if File.size(input) > 2 * 1024 * 1024
data = File.binread(input)
abort 'not an explicitly generated test fixture' unless data.include?('Aether synthetic timestamp fixture')
changed = 0
walk = lambda do |start, limit|
  pos = start
  while pos < limit
    size = data.byteslice(pos, 4)&.unpack1('N')
    kind = data.byteslice(pos + 4, 4)
    abort 'unsupported fixture box' unless size && size >= 8 && pos + size <= limit
    if %w[moov trak mdia minf stbl].include?(kind)
      walk.call(pos + 8, pos + size)
    elsif kind == 'ctts'
      count = data.byteslice(pos + 12, 4).unpack1('N')
      abort 'unexpected ctts length' unless size == 16 + 8 * count
      samples = 0
      count.times do |i|
        offset = pos + 16 + 8 * i
        length = data.byteslice(offset, 4).unpack1('N')
        abort 'fixture GOP boundary must align with ctts run' if samples < first && samples + length > first
        abort 'fixture middle boundary must align with ctts run' if mode == 'middle' && samples < last && samples + length > last
        if samples >= first && (mode == 'tail' || samples < last)
          data[offset + 4, 4] = [0].pack('N')
          changed += length
        end
        samples += length
      end
      abort "expected #{total} generated video frames" unless samples == total
    end
    pos += size
  end
end
walk.call(0, data.bytesize)
abort 'unexpected changed sample count' unless changed == (mode == 'tail' ? total - first : last - first)
File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(data) }
puts "PASS generated partial-ctts fixture healthy_head_samples=#{first} zero_offset_samples=#{changed} mode=#{mode}"
