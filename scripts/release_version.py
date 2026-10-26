#!/usr/bin/env python3
"""Shared bundle versions and GitHub release identity; no repository mutations."""
import argparse
import json
import os
from pathlib import Path
import re


def metadata():
    version = (Path(__file__).resolve().parent.parent / 'VERSION').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('VERSION must contain a numeric major.minor.patch version')
    build = os.environ.get('NOTES_BUILD_NUMBER', '1')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build):
        raise ValueError('NOTES_BUILD_NUMBER must contain one to three numeric components')
    release = os.environ.get('NOTES_RELEASE_VERSION', version)
    if release != version and not re.fullmatch(re.escape(version) + r'-dev\.[1-9][0-9]*\.[1-9][0-9]*', release):
        raise ValueError('NOTES_RELEASE_VERSION must match VERSION or VERSION-dev.RUN.ATTEMPT')
    return dict(version=version, build=build, release=release)


def github_metadata():
    result = metadata()
    run = os.environ['GITHUB_RUN_NUMBER']
    attempt = os.environ['GITHUB_RUN_ATTEMPT']
    if not all(re.fullmatch(r'[1-9][0-9]*', value) for value in (run, attempt)):
        raise ValueError('GitHub run and attempt must be positive integers')
    stable = os.environ['GITHUB_REF_TYPE'] == 'tag'
    if stable and os.environ['GITHUB_REF_NAME'] != 'v' + result['version']:
        raise ValueError('Release tag must equal v followed by VERSION')
    result.update(build=f'{run}.{attempt}',
                  release=result['version'] if stable else f"{result['version']}-dev.{run}.{attempt}",
                  prerelease=str(not stable).lower())
    result['tag'] = 'v' + result['release']
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-output', action='store_true')
    args = parser.parse_args()
    result = github_metadata() if args.github_output else metadata()
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in result.items():
                output.write(f'{key}={value}\n')
    print(json.dumps(result))
