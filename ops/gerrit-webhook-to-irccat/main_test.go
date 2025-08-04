package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	gerritStreams "github.com/andygrunwald/go-gerrit/streams"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var jsonMsgs = []struct {
	in  string
	out string
}{
	{`{"uploader":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"patchSet":{"number":1,"revision":"e135bd7a83994d008b587e166186a95e200dd4b7","parents":["be68d899017ff0d79aa7bc9167381dba131342e0"],"ref":"refs/changes/23/30623/1","uploader":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"createdOn":1753736174,"author":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"kind":"REWORK","sizeInsertions":17,"sizeDeletions":0},"change":{"project":"snix","branch":"canon","id":"If9e2ca897e52ae9aa4da033b52dee6f17e66f636","number":30623,"subject":"feat(ops/machines/*01): install kitty terminfo","owner":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"url":"https://cl.snix.dev/c/snix/+/30623","commitMessage":"feat(ops/machines/*01): install kitty terminfo\n\nChange-Id: If9e2ca897e52ae9aa4da033b52dee6f17e66f636\n","createdOn":1753736174,"status":"NEW"},"project":"snix","refName":"refs/heads/canon","changeKey":{"id":"If9e2ca897e52ae9aa4da033b52dee6f17e66f636"},"type":"patchset-created","eventCreatedOn":1753736174}`,
		`#snix CL/30623 proposed by flokli - feat(ops/machines/*01): install kitty terminfo - https://cl.snix.dev/c/snix/+/30623`},
	{"{\"submitter\":{\"name\":\"Jade Lovelace\",\"email\":\"jade@lix.systems\",\"username\":\"jade\"},\"newRev\":\"be68d899017ff0d79aa7bc9167381dba131342e0\",\"patchSet\":{\"number\":2,\"revision\":\"be68d899017ff0d79aa7bc9167381dba131342e0\",\"parents\":[\"afec95e269e2d59e10fb205eb793d7261b638dc2\"],\"ref\":\"refs/changes/05/30605/2\",\"uploader\":{\"name\":\"Jade Lovelace\",\"email\":\"jade@lix.systems\",\"username\":\"jade\"},\"createdOn\":1753734843,\"author\":{\"name\":\"Jade Lovelace\",\"email\":\"jade@lix.systems\",\"username\":\"jade\"},\"kind\":\"NO_CODE_CHANGE\",\"sizeInsertions\":26,\"sizeDeletions\":1},\"change\":{\"project\":\"snix\",\"branch\":\"canon\",\"id\":\"I65b14839a62c4e779136c1c34750d15cedaaddc8\",\"number\":30605,\"subject\":\"fix(ops/gerrit): send mail with the triggering user\\u0027s name on it\",\"owner\":{\"name\":\"Jade Lovelace\",\"email\":\"jade@lix.systems\",\"username\":\"jade\"},\"url\":\"https://cl.snix.dev/c/snix/+/30605\",\"commitMessage\":\"fix(ops/gerrit): send mail with the triggering user\\u0027s name on it\\n\\nWe found this bug in Lix\\u0027s config and noticed Snix had the same bug; see\\nhttps://git.lix.systems/the-distro/infra/commit/4b9e84fa0a7390b05bfaf82739173875dfe16b66\\nand https://git.lix.systems/the-distro/infra/commit/b47965fe8f472e146d21995db1e852a22f5fa673.\\n\\nChange-Id: I65b14839a62c4e779136c1c34750d15cedaaddc8\\nReviewed-on: https://cl.snix.dev/c/snix/+/30605\\nTested-by: besadii\\nReviewed-by: Florian Klink \\u003cflokli@flokli.de\\u003e\\n\",\"createdOn\":1753663580,\"status\":\"MERGED\"},\"project\":{\"name\":\"snix\"},\"refName\":\"refs/heads/canon\",\"changeKey\":{\"key\":\"I65b14839a62c4e779136c1c34750d15cedaaddc8\"},\"type\":\"change-merged\",\"eventCreatedOn\":1753734843}",
		"#snix CL/30605 applied by jade - fix(ops/gerrit): send mail with the triggering user's name on it - https://cl.snix.dev/c/snix/+/30605"},
	{"{\"submitter\":{\"name\":\"clbot\",\"username\":\"clbot\"},\"newRev\":\"afec95e269e2d59e10fb205eb793d7261b638dc2\",\"patchSet\":{\"number\":2,\"revision\":\"099f14194bcee28133af01a6e324b2fe4ecccd7c\",\"parents\":[\"9942014989bcc56b1a302ef6eb2b9f2e2aecccb8\"],\"ref\":\"refs/changes/99/30599/2\",\"uploader\":{\"name\":\"clbot\",\"username\":\"clbot\"},\"createdOn\":1751906446,\"author\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"kind\":\"NO_CODE_CHANGE\",\"sizeInsertions\":20,\"sizeDeletions\":0},\"change\":{\"project\":\"snix\",\"branch\":\"canon\",\"id\":\"I449101cfda7c8a728d3e2f3be71dee00be780ec3\",\"number\":30599,\"subject\":\"doc(README): point to website once more\",\"owner\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"url\":\"https://cl.snix.dev/c/snix/+/30599\",\"commitMessage\":\"doc(README): point to website once more\\n\\nThere\\u0027s no point in replicating redundant information in many different\\nplaces. Add some more pointers and encouragement to read the docs where\\nthey live.\\n\\nChange-Id: I449101cfda7c8a728d3e2f3be71dee00be780ec3\\nReviewed-on: https://cl.snix.dev/c/snix/+/30599\\nTested-by: besadii\\nReviewed-by: Vova Kryachko \\u003cv.kryachko@gmail.com\\u003e\\nAutosubmit: Florian Klink \\u003cflokli@flokli.de\\u003e\\n\",\"createdOn\":1751899755,\"status\":\"MERGED\"},\"project\":{\"name\":\"snix\"},\"refName\":\"refs/heads/canon\",\"changeKey\":{\"key\":\"I449101cfda7c8a728d3e2f3be71dee00be780ec3\"},\"type\":\"change-merged\",\"eventCreatedOn\":1751906446}",
		"#snix CL/30599 by flokli autosubmitted - doc(README): point to website once more - https://cl.snix.dev/c/snix/+/30599"},
	{"{\"changer\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"patchSet\":{\"number\":5,\"revision\":\"944b6f97be4cad910f7a831a9a24e5d3da06d77b\",\"parents\":[\"424d56733e9254dc4609ab2abed2b1ea24e7f514\"],\"ref\":\"refs/changes/28/30628/5\",\"uploader\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"createdOn\":1753962503,\"author\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"kind\":\"TRIVIAL_REBASE\",\"sizeInsertions\":16,\"sizeDeletions\":3},\"change\":{\"project\":\"snix\",\"branch\":\"canon\",\"id\":\"I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\",\"number\":30628,\"subject\":\"chore(3p/nixpkgs): bump channels (2025-07-31)\",\"owner\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"url\":\"https://cl.snix.dev/c/snix/+/30628\",\"commitMessage\":\"chore(3p/nixpkgs): bump channels (2025-07-31)\\n\\nChange-Id: I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\\n\",\"createdOn\":1753953838,\"status\":\"NEW\"},\"project\":\"snix\",\"refName\":\"refs/heads/canon\",\"changeKey\":{\"id\":\"I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\"},\"type\":\"wip-state-changed\",\"eventCreatedOn\":1753963017}",
		"#snix CL/30628 undrafted by flokli - chore(3p/nixpkgs): bump channels (2025-07-31) - https://cl.snix.dev/c/snix/+/30628"},
	{"{\"changer\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"patchSet\":{\"number\":5,\"revision\":\"944b6f97be4cad910f7a831a9a24e5d3da06d77b\",\"parents\":[\"424d56733e9254dc4609ab2abed2b1ea24e7f514\"],\"ref\":\"refs/changes/28/30628/5\",\"uploader\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"createdOn\":1753962503,\"author\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"kind\":\"TRIVIAL_REBASE\",\"sizeInsertions\":16,\"sizeDeletions\":3},\"change\":{\"project\":\"snix\",\"branch\":\"canon\",\"id\":\"I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\",\"number\":30628,\"subject\":\"chore(3p/nixpkgs): bump channels (2025-07-31)\",\"owner\":{\"name\":\"Florian Klink\",\"email\":\"flokli@flokli.de\",\"username\":\"flokli\"},\"url\":\"https://cl.snix.dev/c/snix/+/30628\",\"commitMessage\":\"chore(3p/nixpkgs): bump channels (2025-07-31)\\n\\nChange-Id: I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\\n\",\"createdOn\":1753953838,\"status\":\"NEW\",\"wip\":true},\"project\":\"snix\",\"refName\":\"refs/heads/canon\",\"changeKey\":{\"id\":\"I1ae84e743281125ecbdc98cdb4f2adf5a96905a7\"},\"type\":\"wip-state-changed\",\"eventCreatedOn\":1753963011}",
		""},
}

func TestParseChangeProposed(t *testing.T) {
	for _, tt := range jsonMsgs {
		var event gerritStreams.Event
		err := json.Unmarshal([]byte(tt.in), &event)
		require.NoError(t, err, "json unmarshal")

		var msg bytes.Buffer
		err = tmpl.Execute(&msg, event)
		require.NoError(t, err, "tmpl execute")

		msgStr := strings.TrimSpace(msg.String())

		assert.Equal(t, tt.out, msgStr)

	}

}
