{ here, ... }: {
  attr1 = "foo";
  attr2 = here.attr1;

  attr3 = here.subdir.sibl2;
}
