#
# Be sure to run `pod lib lint SlouchDB4.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'SlouchDB4'
  s.version          = '0.1.0'
  s.summary          = 'A distributed, single-user database'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
SlouchDB4 is a distributed, single-user database that uses third party storage
as the sync mechanism.
                       DESC

  s.homepage         = 'https://github.com/allenu/slouchdb4'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'allenu' => '1897128+allenu@users.noreply.github.com' }
  s.source           = { :git => 'https://github.com/allenu/slouchdb4.git', :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/ussherpress'

  s.ios.deployment_target = '11.0'
  s.osx.deployment_target = '10.14'

  s.source_files = 'SlouchDB4/Classes/**/*'
  s.swift_versions = ['5.0']

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'SlouchDB4/Tests/*.swift'
    # test_spec.dependency 'OCMock' # This dependency will only be linked with your tests.
  end

end
