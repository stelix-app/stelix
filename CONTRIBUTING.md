# Contributing

Bug reports, ideas and pull requests are welcome.

## Before you open a pull request

- Open an issue first for anything larger than a small fix, so the approach can be agreed before you spend time on it.
- Build and test with the scripts of the repository: `scripts/build.sh --no-install`, `scripts/test.sh` and `scripts/lint-ui.sh` must pass.
- Write code, comments and commit messages in English.
- Never add model weights, audio files or personal data to the repository.
- A new or updated dependency changes the list of third-party licenses: run `scripts/third-party-notices.py` and commit the result. The build fails if that file is out of date.
- New source files start with the same two-line license header as the existing ones.

## License of your contribution

By submitting a contribution (a pull request, a patch or any other change) you agree to the following.

1. You wrote it, or you otherwise have the right to submit it under these terms. The [Developer Certificate of Origin 1.1](https://developercertificate.org) describes what that means.
2. Your contribution is licensed to everyone under the license of the project: the GNU General Public License, version 3, with the additional terms in [NOTICE](NOTICE).
3. You also grant Gabriele Carsana, the copyright holder of the project, a perpetual, worldwide, non-exclusive, royalty-free and irrevocable license to use, reproduce, modify, distribute and sublicense your contribution under other license terms as well.

Point 3 is what allows the project to be published in places whose rules do not fit the GPL, such as app stores. It takes nothing away from point 2: your contribution stays available to everyone under the GPL, and you keep the copyright on it.

If you cannot agree to these terms, please open an issue describing the change instead of sending code.
