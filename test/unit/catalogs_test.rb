require "test_helper"

class CatalogsTest < Minitest::Test
  def catalogs(*patterns) = DialectoRails::Scan::Catalogs.new(patterns)

  def test_double_star_spans_folders_including_none
    c = catalogs("config/locales/**/*.yml")
    assert c.match?("config/locales/en.yml")
    assert c.match?("config/locales/models/user.en.yml")
    assert c.match?("config/locales/a/b/c/x.yml")
    refute c.match?("config/locales/en.yaml")
    refute c.match?("app/config/locales/en.yml")
  end

  def test_single_star_stays_in_one_folder
    c = catalogs("config/locales/*.yml")
    assert c.match?("config/locales/en.yml")
    refute c.match?("config/locales/models/en.yml")
  end

  def test_question_mark_is_one_character
    c = catalogs("config/locales/?.yml")
    assert c.match?("config/locales/a.yml")
    refute c.match?("config/locales/ab.yml")
  end

  def test_no_wildcard_reaches_a_dot_folder_or_file
    c = catalogs("config/**/*.yml")
    assert c.match?("config/locales/en.yml")
    refute c.match?("config/.secrets/x.yml")
    refute c.match?("config/locales/.hidden.yml")
  end

  def test_literal_characters_are_not_regex
    c = catalogs("config/locales/en+us.yml")
    assert c.match?("config/locales/en+us.yml")
    refute c.match?("config/locales/enus.yml")
  end

  def test_any_of_several_patterns
    c = catalogs("config/locales/**/*.yml", "engines/*/config/locales/*.yml")
    assert c.match?("engines/admin/config/locales/en.yml")
    refute c.match?("engines/admin/other/en.yml")
  end
end
