EMACS ?= emacs

# A space-separated list of required package names
DEPS = seq inheritenv

INIT_PACKAGES := "(progn \
  (require 'package) \
  (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) \
  (package-initialize) \
  (dolist (pkg '(PACKAGES)) \
    (unless (package-installed-p pkg) \
      (unless (assoc pkg package-archive-contents) \
        (package-refresh-contents)) \
      (package-install pkg))) \
  )"

all: compile test package-lint clean

test: test-sync test-async
test-sync: SYNC_MODE = --eval "(setq ben-async-processing nil)"
test-%:
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) ${SYNC_MODE} -batch -l ben.el -l ben-tests.el -f ert-run-tests-batch-and-exit

package-lint:
	${EMACS} -Q --eval $(subst PACKAGES,package-lint,${INIT_PACKAGES}) -batch -f package-lint-batch-and-exit ben.el

compile: clean
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -batch -f batch-byte-compile *.el

clean:
	rm -f *.elc

.PHONY:	all compile clean package-lint
