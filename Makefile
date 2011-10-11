include version.mk
ERLANG_ROOT := $(shell erl -eval 'io:format("~s", [code:root_dir()])' -s init stop -noshell)
ERLDIR=$(ERLANG_ROOT)/lib/erlyvideo-$(VERSION)
DESTROOT:=$(CURDIR)/debian/erlyvideo
ERL_LIBS:=apps:deps:plugins



# NIFDIR := `erl -eval 'io:format("~s", [code:lib_dir(erts,include)])' -s init stop -noshell| sed s'/erlang\/lib\//erlang\//'`
#
# ifeq ($(shell uname), Linux)
# NIF_FLAGS := gcc -shared -O3 -fPIC -fno-common -Wall
# endif
#
# ifeq ($(shell uname), Darwin)
# NIF_FLAGS := cc -arch i386 -arch x86_64 -pipe -bundle -undefined dynamic_lookup -O3 -fPIC -fno-common -Wall
# endif
#
# ifeq ($(shell uname), FreeBSD)
# NIF_FLAGS := cc -shared -O3 -fPIC -fno-common -Wall
# endif

ERL=erl +A 4 +K true
APP_NAME=ems
AMAZON=root@ec2-50-17-96-238.compute-1.amazonaws.com:/root
AMAZON_HOST=root@ec2-50-17-96-238.compute-1.amazonaws.com
all: compile

update:
	git pull

escriptize: compile
	./contrib/escriptize

amazon_update: release
	tar cvfp erlyvideo.tar.bz2 ./erlyvideo/ 
	rsync erlyvideo.tar.bz2 $(AMAZON)
	ssh $(AMAZON_HOST) './script.sh'
compile:
	./rebar get-deps
	./rebar compile

release: clean compile
	./rebar generate force=1
	chmod +x erlyvideo/bin/erlyvideo

ebin/mmap.so: src/core/mmap.c
	$(NIF_FLAGS) -o $@ $< -I $(NIFDIR) || touch $@

archive:
	git archive --prefix=erlyvideo-$(VERSION)/ v$(VERSION) | gzip -9 > ../erlyvideo-$(VERSION).tar.gz

tgz: release
	tar zcvf erlyvideo-$(VERSION).tar.gz erlyvideo


clean:
	./rebar clean
	rm -fv plugins/*/ebin/*.beam
	rm -fv erl_crash.dump
	rm -fv erlyvideo.tar.bz2

clean-doc:
	rm -fv doc/*.html
	rm -fv doc/edoc-info
	rm -fv doc/*.css

run: priv/erlyvideo.conf priv/log4erl.conf 
	ERL_LIBS=apps:..:deps:../commercial/apps erl -args_file files/vm.args -sname ev -boot start_sasl -s erlyvideo -config files/app.config

priv/log4erl.conf: priv/log4erl.conf.sample
	[ -f priv/log4erl.conf ] || cp priv/log4erl.conf.sample priv/log4erl.conf

priv/erlyvideo.conf: priv/erlyvideo.conf.sample
	[ -f priv/erlyvideo.conf ] || cp priv/erlyvideo.conf.sample priv/erlyvideo.conf


version:
	echo "VERSION=$(VER)" > version.mk
	git add version.mk
	git commit -m "Version $(VER)"
	# git tag -s v$(VER) -m "version $(VER)"

packages: release
	rm -rf tmproot
	tar zcf erlyvideo-$(VERSION).tgz erlyvideo
	mkdir -p tmproot/opt
	mv erlyvideo tmproot/opt/
	mkdir -p tmproot/etc/init.d/
	cp contrib/erlyvideo tmproot/etc/init.d/
	mkdir -p tmproot/etc/erlyvideo
	mkdir -p tmproot/opt/erlyvideo/lib/erl_interface/ebin tmproot/opt/erlyvideo/lib/erl_interface/include
	cp priv/erlyvideo.conf.sample tmproot/etc/erlyvideo/erlyvideo.conf.sample
	cp priv/log4erl.conf.sample tmproot/etc/erlyvideo/log4erl.conf.sample
	cd tmproot && \
	fpm -s dir -t deb -n erlyvideo -v $(VERSION) -m "Max Lapshin <max@maxidoors.ru>" etc/init.d/erlyvideo etc/erlyvideo opt 
	mv tmproot/*.deb .

upload_packages: 
	scp *$(VERSION)* erlyhub@git.erlyvideo.org:/apps/erlyvideo/debian/public/binary
	ssh erlyhub@git.erlyvideo.org "cd /apps/erlyvideo/debian ; ./update ; cd public/binary ; ln -sf erlyvideo-$(VERSION).tgz erlyvideo-latest.tgz "
	echo "Erlyvideo version ${VERSION} uploaded to debian repo http://debian.erlyvideo.org/ ." | mail -r "Erlybuild <build@erlyvideo.org>" -s "Erlyvideo version ${VERSION}" -v erlyvideo-dev@googlegroups.com

.PHONY: doc debian compile

