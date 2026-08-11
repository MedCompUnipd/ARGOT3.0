#!/usr/bin/python3

import argparse


def get_args():
    parser = argparse.ArgumentParser()

    parser.add_argument('-i', '--input', required=True)
    parser.add_argument('-u', '--upr', required=True)
    parser.add_argument('-o', '--output', required=True)

    return vars(parser.parse_args())


if __name__ == '__main__':
    args = get_args()
    prot_file = args['input']
    upr_file = args['upr']
    out_file = args['output']

    with open(prot_file, 'r') as fp:
        prots = {x.strip() for x in fp.readlines()}

    with open(upr_file, 'r') as fp, open(out_file, 'w') as out:
        write = False
        for line in fp:
            if line.startswith('>'):
                prot = line[1:].split(maxsplit=1)[0]
                write = True if prot in prots else False
            if write:
                out.write(line)
