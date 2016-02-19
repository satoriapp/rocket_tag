require 'spec_helper'

describe RocketTag::Tag do
  before :each do
    clean_database!
  end

  describe '#by_taggable_type' do
    it 'finds tags by taggable_type' do
      taggable_model = TaggableModel.create :skills => %q%cat, dogs%
      tags = taggable_model.tags
      RocketTag::Tag.by_taggable_type('TaggableModel').to_a.should == tags.to_a
    end

    it 'finds nothing if we there are no taggings with provided taggable_type' do
      RocketTag::Tag.by_taggable_type('ModelISNotExist').should be_empty
    end
  end
end
