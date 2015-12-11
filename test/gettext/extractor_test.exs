defmodule Gettext.ExtractorTest do
  use ExUnit.Case
  alias Gettext.Extractor
  alias Gettext.PO
  alias Gettext.PO.Translation

  @pot_path "../../tmp/" |> Path.expand(__DIR__) |> Path.relative_to_cwd

  test "merge_pot_files/2" do
    paths = %{
      tomerge: Path.join(@pot_path, "tomerge.pot"),
      ignored: Path.join(@pot_path, "ignored.pot"),
      new: Path.join(@pot_path, "new.pot"),
    }

    extracted_po_structs = [
      {paths.tomerge, %PO{translations: [%Translation{msgid: ["other"], msgstr: [""]}]}},
      {paths.new, %PO{translations: [%Translation{msgid: ["new"], msgstr: [""]}]}},
    ]

    write_file paths.tomerge, """
    msgid "foo"
    msgstr ""
    """

    write_file paths.ignored, """
    msgid "ignored"
    msgstr ""
    """

    structs = Extractor.merge_pot_files([paths.tomerge, paths.ignored], extracted_po_structs)

    # Unchanged files are not returned
    assert List.keyfind(structs, paths.ignored, 0) == nil

    {_, contents} = List.keyfind(structs, paths.tomerge, 0)
    assert IO.iodata_to_binary(contents) == """
    msgid "foo"
    msgstr ""

    msgid "other"
    msgstr ""
    """

    {_, contents} = List.keyfind(structs, paths.new, 0)
    contents = IO.iodata_to_binary(contents)
    assert String.starts_with?(contents, "## This file is a PO Template file.")
    assert contents =~ """
    msgid "new"
    msgstr ""
    """
  end

  test "merge_template/2: non-autogenerated translations are kept" do
    # No autogenerated translations
    t1 = %Translation{msgid: ["foo"], msgstr: ["bar"]}
    t2 = %Translation{msgid: ["baz"], msgstr: ["bong"]}
    t3 = %Translation{msgid: ["a", "b"], msgstr: ["c", "d"]}
    old = %PO{translations: [t1]}
    new = %PO{translations: [t2, t3]}

    assert Extractor.merge_template(old, new) == %PO{translations: [t1, t2, t3]}
  end

  test "merge_template/2: obsolete autogenerated translations are discarded" do
    # Autogenerated translations
    t1 = %Translation{msgid: ["foo"], msgstr: ["bar"], references: [{"foo.ex", 1}]}
    t2 = %Translation{msgid: ["baz"], msgstr: ["bong"]}
    old = %PO{translations: [t1]}
    new = %PO{translations: [t2]}

    assert Extractor.merge_template(old, new) == %PO{translations: [t2]}
  end

  test "merge_template/2: matching translations are merged" do
    ts1 = [
      %Translation{msgid: ["foo"], references: [{"foo.ex", 2}]},
      %Translation{msgid: ["bar"], references: [{"foo.ex", 1}]},
    ]
    ts2 = [
      %Translation{msgid: ["baz"]},
      %Translation{msgid: ["foo"], references: [{"foo.ex", 3}]},
    ]

    assert Extractor.merge_template(%PO{translations: ts1}, %PO{translations: ts2}) == %PO{translations: [
      %Translation{msgid: ["foo"], references: [{"foo.ex", 3}]},
      %Translation{msgid: ["baz"]},
    ]}
  end

  test "merge_template/2: headers are taken from the oldest PO file" do
    po1 = %PO{headers: ["Last-Translator: Foo", "Content-Type: text/plain"]}
    po2 = %PO{headers: ["Last-Translator: Bar"]}

    assert Extractor.merge_template(po1, po2) == %PO{headers: [
      "Last-Translator: Foo",
      "Content-Type: text/plain",
    ]}
  end

  test "merge_template/2: non-empty msgstrs raise an error" do
    po1 = %PO{translations: [%Translation{msgid: "foo", msgstr: "bar"}]}
    po2 = %PO{translations: [%Translation{msgid: "foo", msgstr: "bar"}]}

    msg = "translation with msgid 'foo' has a non-empty msgstr"
    assert_raise Gettext.Error, msg, fn ->
      Extractor.merge_template(po1, po2)
    end
  end

  test "extraction process" do
    refute Extractor.extracting?
    Extractor.setup
    assert Extractor.extracting?

    code = """
    defmodule Gettext.ExtractorTest.MyGettext do
      use Gettext, otp_app: :test_application
    end

    defmodule Gettext.ExtractorTest.MyOtherGettext do
      use Gettext, otp_app: :test_application, priv: "translations"
    end

    defmodule Foo do
      import Gettext.ExtractorTest.MyGettext
      require Gettext.ExtractorTest.MyOtherGettext

      def bar do
        gettext "foo"
        dngettext "errors", "one error", "%{count} errors", 2
        gettext "foo"
        Gettext.ExtractorTest.MyOtherGettext.dgettext "greetings", "hi"
      end
    end
    """

    Code.compile_string(code, Path.join(File.cwd!, "foo.ex"))

    expected = [
      {"priv/gettext/default.pot",
        """
        #: foo.ex:14 foo.ex:16
        msgid "foo"
        msgstr ""
        """},

      {"priv/gettext/errors.pot",
          """
          #: foo.ex:15
          msgid "one error"
          msgid_plural "%{count} errors"
          msgstr[0] ""
          msgstr[1] ""
          """},

      {"translations/greetings.pot",
          """
          #: foo.ex:17
          msgid "hi"
          msgstr ""
          """}
    ]

    dumped = Enum.map(Extractor.pot_files, fn {k, v} -> {k, IO.iodata_to_binary(v)} end)

    # We check that dumped strings end with the `expected` string because
    # there's the informative comment at the start of each dumped string.
    assert Enum.all?(dumped, fn {path, contents} ->
      {^path, expected_contents} = List.keyfind(expected, path, 0)
      String.ends_with?(contents, expected_contents)
    end)
    assert Enum.all?(dumped, fn {_, contents} ->
      contents =~ "## This file is a PO Template file."
    end)
    Extractor.teardown
    refute Extractor.extracting?
  end

  defp write_file(path, contents) do
    path |> Path.dirname |> File.mkdir_p!
    File.write!(path, contents)
  end
end
