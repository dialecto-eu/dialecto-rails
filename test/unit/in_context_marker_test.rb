require "test_helper"
require "dialecto_rails/in_context/marker"

# The same vectors the Phoenix add-on tests (sdk/phoenix marker_test.exs), the Astro add-on's encodeMark and
# the overlay's codec.js agree on.
class InContextMarkerTest < Minitest::Test
  Marker = DialectoRails::InContext::Marker
  DIGITS = [0x200C, 0x200D, 0x2060, 0x2061].freeze

  def codepoints(text) = text.codepoints

  def digits(list) = list.map { |digit| DIGITS[digit] }

  def test_the_codepoints_are_spec_0016s
    assert_equal [0x2062], codepoints(Marker::OPEN)
    assert_equal [0x2063], codepoints(Marker::HEADER_END)
    assert_equal [0x2064], codepoints(Marker::CLOSE)
    assert_equal DIGITS, Marker::DIGITS.map { |digit| digit.codepoints.first }
  end

  def test_the_astro_golden_vector_in_full
    expected = [0x2062] + digits([1, 2, 1, 0, 0, 1, 3, 3, 1, 2, 2, 3, 0, 1, 3, 3, 1, 2, 1, 1]) + [0x2063, "x".ord, 0x2064]
    assert_equal expected, codepoints(Marker.mark("d", "k", "e", "x"))
    assert_equal [0x200D, 0x2060, 0x200D, 0x200C], expected[1, 4]
  end

  def test_a_gettext_context_key_and_multibyte_utf8
    expected = [0x2062] +
      digits([1, 2, 3, 1, 0, 1, 3, 3, 1, 2, 0, 3, 0, 0, 1, 0, 3, 0, 0, 3, 2, 2, 2, 1]) +
      digits([0, 1, 3, 3, 1, 2, 1, 1, 1, 3, 0, 3]) + [0x2063, 0x2064]
    assert_equal expected, codepoints(Marker.mark("m", "c\u0004é", "es", ""))
  end

  def test_recorded_args_follow_the_record_separator
    expected = [0x2062] +
      digits([1, 2, 1, 0, 0, 1, 3, 3, 1, 2, 2, 3, 0, 1, 3, 3, 1, 2, 1, 1]) +
      digits([0, 1, 3, 2, 1, 3, 2, 3, 0, 2, 0, 2, 1, 2, 3, 2, 0, 2, 0, 2]) +
      digits([0, 3, 2, 2, 0, 3, 0, 1, 1, 3, 3, 1]) + [0x2063, "x".ord, 0x2064]
    assert_equal expected, codepoints(Marker.mark("d", "k", "e", "x", %({"n":1})))
  end

  def test_round_trips_identity_args_and_text
    segment = Marker.parse(Marker.mark("en.yml", "a.b", "en", "Héllo", %({"n":1}))).first
    assert_equal ["en.yml", "a.b", "en", "Héllo"], [segment.domain, segment.key, segment.locale, segment.text]
    assert_equal({"n" => 1}, segment.args)
    refute segment.open
  end

  def test_nested_marks_parse_outer_first_and_strip_to_clean_text
    inner = Marker.mark("d", "inner", "en", "in")
    text = Marker.mark("d", "outer", "en", "a #{inner} b")
    assert_equal %w[outer inner], Marker.parse(text).map(&:key)
    assert_equal "a in b", Marker.strip(text)
  end

  def test_malformed_headers_and_unbalanced_closes_are_ignored_and_a_lone_open_runs_to_the_end
    assert_equal "plain", Marker.strip("plain#{Marker::CLOSE}")
    assert_empty Marker.parse("x#{Marker::CLOSE}")
    lone = Marker.prefix("d", "k", "en") + "tail"
    segment = Marker.parse(lone).first
    assert segment.open
    assert_equal "tail", segment.text
  end

  def test_strip_keeps_a_real_zwj_that_is_not_part_of_a_header
    assert_equal "a‍b", Marker.strip("a‍b")
  end
end
