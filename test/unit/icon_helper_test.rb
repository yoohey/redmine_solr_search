# frozen_string_literal: true

require_relative '../light_helper'

# Icons with or without Redmine 6.0's sprite_icon (design D-62)
class IconHelperTest < Minitest::Test
  # A view of Redmine 5.1: no sprite_icon
  class OldView
    include SolrSearch::IconHelper
  end

  # A view of Redmine 6.0 and later: sprite_icon draws the SVG and the text
  class NewView
    include SolrSearch::IconHelper

    def sprite_icon(name, label = nil)
      "<svg #{name}/>#{label}"
    end
  end

  def test_redmine_six_draws_the_icon
    assert_equal '<svg checked/>OK', NewView.new.solr_search_icon('checked', 'OK')
  end

  def test_redmine_five_shows_the_text_alone_escaped
    assert_equal 'a &lt;b&gt; &amp; c', OldView.new.solr_search_icon('checked', 'a <b> & c')
    assert_equal '', OldView.new.solr_search_icon('')
  end
end
