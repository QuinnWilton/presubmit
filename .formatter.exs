[
  inputs: ["{mix,.formatter,.assert_commit}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [rule: 3, rule: 4, assert_pass: 1, assert_fail: 2],
  export: [locals_without_parens: [rule: 3, rule: 4]]
]
